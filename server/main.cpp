#include "runtime.hpp"

#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace net = boost::asio;
namespace beast = boost::beast;
namespace ws = beast::websocket;
using tcp = net::ip::tcp;
using Json = Runtime::Json;
using namespace std::chrono_literals;

namespace {
class Hub;

class Session : public std::enable_shared_from_this<Session> {
public:
    Session(tcp::socket socket, Hub& hub) : socket_(std::move(socket)), hub_(hub) {}
    void start();
    void send(std::string message);
    void stop();
    std::string id;

private:
    void read();
    void write();
    ws::stream<beast::tcp_stream> socket_;
    Hub& hub_;
    beast::flat_buffer input_;
    std::deque<std::string> output_;
    bool stopped_ = false;
};

class Hub {
public:
    Hub(net::io_context& context, const tcp::endpoint& endpoint, Runtime& world,
        std::map<std::string, std::string> tokens)
        : listener_(context, endpoint), timer_(context), world_(world), tokens_(std::move(tokens)) {}

    void start() { accept(); schedule_tick(); }

    void stop() {
        listener_.close();
        timer_.cancel();
        const std::vector sessions(sessions_.begin(), sessions_.end());
        for (const auto& session : sessions) session->stop();
    }

    void remove(const std::shared_ptr<Session>& session) {
        sessions_.erase(session);
        if (!session->id.empty() && world_.leave(session->id)) broadcast();
    }

    void handle(Session& session, const std::string& message) {
        Json request = Json::parse(message, nullptr, false);
        if (!request.is_object() || !request.contains("type") || !request["type"].is_string()) {
            error(session, "invalid_request");
            return;
        }
        // Only the small, flat command surface is passed into Lua.
        Json command = {{"type", request["type"]}};
        if (session.id.empty()) {
            if (request["type"] != "login") {
                error(session, "unauthenticated");
                return;
            }
            const auto token = request.find("token");
            const auto player = token != request.end() && token->is_string()
                ? tokens_.find(token->get_ref<const std::string&>()) : tokens_.end();
            if (player == tokens_.end()) {
                error(session, "bad_token");
                return;
            }
            auto [reply, changed] = world_.join(player->second);
            if (changed) session.id = player->second;
            session.send(reply.dump());
            if (changed) broadcast();
            return;
        }

        for (const auto* field : {"dx", "dy", "target"}) {
            auto value = request.find(field);
            if (value != request.end() && value->is_primitive()) command[field] = *value;
        }
        const auto [reply, changed] = world_.request(session.id, command);
        session.send(reply.dump());
        if (changed) broadcast();
    }

private:
    static void error(Session& session, const char* code) {
        session.send(Json{{"type", "error"}, {"code", code}}.dump());
    }

    void accept() {
        listener_.async_accept([this](beast::error_code error, tcp::socket socket) {
            if (!error && sessions_.size() < 32) {
                auto session = std::make_shared<Session>(std::move(socket), *this);
                sessions_.insert(session);
                session->start();
            }
            if (listener_.is_open()) accept();
        });
    }

    void schedule_tick() {
        timer_.expires_after(100ms);
        timer_.async_wait([this](beast::error_code error) {
            if (error) return;
            if (world_.tick()) broadcast();
            schedule_tick();
        });
    }

    void broadcast() {
        const auto message = world_.snapshot().dump();
        const std::vector sessions(sessions_.begin(), sessions_.end());
        for (const auto& session : sessions)
            if (!session->id.empty()) session->send(message);
    }

    tcp::acceptor listener_;
    net::steady_timer timer_;
    Runtime& world_;
    std::map<std::string, std::string> tokens_;
    std::set<std::shared_ptr<Session>> sessions_;
};

void Session::start() {
    socket_.set_option(ws::stream_base::timeout::suggested(beast::role_type::server));
    socket_.read_message_max(8192);
    socket_.async_accept([self = shared_from_this()](beast::error_code error) {
        if (error) self->stop();
        else self->read();
    });
}

void Session::read() {
    if (stopped_) return;
    socket_.async_read(input_, [self = shared_from_this()](beast::error_code error, std::size_t) {
        if (error || !self->socket_.got_text()) {
            self->stop();
            return;
        }
        const auto payload = beast::buffers_to_string(self->input_.data());
        self->input_.consume(self->input_.size());
        try {
            self->hub_.handle(*self, payload);
        } catch (const std::exception&) {
            self->send(R"({"type":"error","code":"internal_error"})");
        }
        self->read();
    });
}

void Session::send(std::string message) {
    if (stopped_) return;
    if (output_.size() >= 64) {
        net::post(socket_.get_executor(), [self = shared_from_this()] { self->stop(); });
        return;
    }
    output_.push_back(std::move(message));
    if (output_.size() == 1) write();
}

void Session::write() {
    socket_.text(true);
    socket_.async_write(net::buffer(output_.front()),
        [self = shared_from_this()](beast::error_code error, std::size_t) {
            if (error) {
                self->stop();
                return;
            }
            self->output_.pop_front();
            if (!self->stopped_ && !self->output_.empty()) self->write();
        });
}

void Session::stop() {
    if (stopped_) return;
    stopped_ = true;
    beast::error_code ignored;
    beast::get_lowest_layer(socket_).socket().close(ignored);
    hub_.remove(shared_from_this());
    id.clear();
}

std::string config(const char* name, const char* fallback = "") {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

std::map<std::string, std::string> player_tokens() {
    const auto players = Json::parse(config("FERRY_PLAYERS"), nullptr, false);
    if (!players.is_object() || players.empty() || players.size() > 32)
        throw std::runtime_error("Set FERRY_PLAYERS to an object of player IDs and access tokens.");
    std::map<std::string, std::string> tokens;
    for (const auto& [id, value] : players.items()) {
        if (id.empty() || id.size() > 24 || id.find_first_not_of(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-") != std::string::npos
            || !value.is_string())
            throw std::runtime_error("Invalid player ID or token.");
        const auto& token = value.get_ref<const std::string&>();
        if (token.size() < 24 || token.size() > 128 || !tokens.emplace(token, id).second)
            throw std::runtime_error("Tokens must be distinct and have 24 to 128 characters.");
    }
    return tokens;
}
}  // namespace

int main(int argc, char** argv) {
    try {
        const auto tokens = player_tokens();
        const auto port = std::stoi(config("FERRY_PORT", "7670"));
        if (port < 1 || port > 65535) throw std::runtime_error("Invalid FERRY_PORT.");
        const auto uri = config("FERRY_MONGO_URI");
        if (uri.empty()) throw std::runtime_error("Set FERRY_MONGO_URI on the game server.");
        const std::string database = config("FERRY_MONGO_DB", "ferry_demo");
        const auto script = argc > 1 ? argv[1] : "lua/world.lua";
        net::io_context context(1);
        const auto address = net::ip::make_address(config("FERRY_BIND", "127.0.0.1"));
        Runtime world(uri, database, script);
        Hub hub(context, {address, static_cast<unsigned short>(port)}, world, tokens);
        net::signal_set signals(context, SIGINT, SIGTERM);
        signals.async_wait([&hub](beast::error_code error, int) { if (!error) hub.stop(); });
        hub.start();
        std::cout << "Ferry world ready on " << address.to_string() << ':' << port << std::endl;
        context.run();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
