#include "runtime.hpp"

#include <mongoc/mongoc.h>
#include <lua.hpp>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {
using Json = Runtime::Json;

struct MongoDriver {
    MongoDriver() { mongoc_init(); }
    ~MongoDriver() { mongoc_cleanup(); }
};

struct Bson {
    bson_t value = BSON_INITIALIZER;
    ~Bson() { bson_destroy(&value); }
    bson_t* get() { return &value; }
};

void push_json(lua_State* lua, const Json& value) {
    if (value.is_boolean()) {
        lua_pushboolean(lua, value.get<bool>());
    } else if (value.is_number_unsigned()) {
        const auto number = value.get<std::uint64_t>();
        if (number <= static_cast<std::uint64_t>(LUA_MAXINTEGER)) lua_pushinteger(lua, number);
        else lua_pushnumber(lua, value.get<double>());
    } else if (value.is_number_integer()) {
        lua_pushinteger(lua, value.get<lua_Integer>());
    } else if (value.is_number()) {
        lua_pushnumber(lua, value.get<double>());
    } else if (value.is_string()) {
        const auto& string = value.get_ref<const std::string&>();
        lua_pushlstring(lua, string.data(), string.size());
    } else if (value.is_array()) {
        lua_createtable(lua, static_cast<int>(value.size()), 0);
        lua_Integer index = 1;
        for (const auto& element : value) {
            push_json(lua, element);
            lua_rawseti(lua, -2, index++);
        }
    } else if (value.is_object()) {
        lua_createtable(lua, 0, static_cast<int>(value.size()));
        for (const auto& [key, element] : value.items()) {
            lua_pushlstring(lua, key.data(), key.size());
            push_json(lua, element);
            lua_rawset(lua, -3);
        }
    } else {
        lua_pushnil(lua);
    }
}

Json read_lua(lua_State* lua, int index) {
    index = lua_absindex(lua, index);
    switch (lua_type(lua, index)) {
        case LUA_TBOOLEAN: return static_cast<bool>(lua_toboolean(lua, index));
        case LUA_TNUMBER:
            if (lua_isinteger(lua, index)) return lua_tointeger(lua, index);
            return lua_tonumber(lua, index);
        case LUA_TSTRING: {
            std::size_t size = 0;
            const char* value = lua_tolstring(lua, index, &size);
            return std::string(value, size);
        }
        case LUA_TTABLE: {
            const auto length = lua_rawlen(lua, index);
            if (length > 0) {
                auto result = Json::array();
                for (std::size_t i = 1; i <= length; ++i) {
                    lua_rawgeti(lua, index, static_cast<lua_Integer>(i));
                    result.push_back(read_lua(lua, -1));
                    lua_pop(lua, 1);
                }
                return result;
            }
            auto result = Json::object();
            lua_pushnil(lua);
            while (lua_next(lua, index) != 0) {
                if (lua_type(lua, -2) == LUA_TSTRING) {
                    std::size_t size = 0;
                    const char* key = lua_tolstring(lua, -2, &size);
                    result[std::string(key, size)] = read_lua(lua, -1);
                }
                lua_pop(lua, 1);
            }
            return result;
        }
        case LUA_TNIL: return nullptr;
        default: throw std::runtime_error("unsupported Lua value");
    }
}

struct StackScope {
    lua_State* lua;
    int top;
    explicit StackScope(lua_State* state) : lua(state), top(lua_gettop(state)) {}
    ~StackScope() { lua_settop(lua, top); }
};

std::string lua_error_text(lua_State* state) {
    const char* message = lua_tostring(state, -1);
    return message ? message : "Lua error";
}

Json failure(const char* code) {
    return {{"type", "error"}, {"code", code}};
}

Json read_json_file(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) throw std::runtime_error("Could not open data file: " + path.string());
    return Json::parse(input);
}

Json load_content(const std::filesystem::path& script) {
    const char* env_dir = std::getenv("FERRY_DATA_DIR");
    std::filesystem::path data_dir = (env_dir && *env_dir)
        ? std::filesystem::path(env_dir)
        : script.parent_path().parent_path() / "data";
    if (!std::filesystem::exists(data_dir)) data_dir = "data";
    const auto maps_dir = data_dir / "maps";
    if (!std::filesystem::is_directory(maps_dir))
        throw std::runtime_error("Missing data/maps directory: " + maps_dir.string());

    Json content = {{"maps", Json::object()}, {"quests", Json::object()}};
    for (const auto& entry : std::filesystem::directory_iterator(maps_dir)) {
        if (!entry.is_regular_file() || entry.path().extension() != ".json") continue;
        auto map_def = read_json_file(entry.path());
        const std::string map_id = map_def.contains("id") && map_def["id"].is_string()
            ? map_def["id"].get<std::string>()
            : entry.path().stem().string();
        map_def["id"] = map_id;
        content["maps"][map_id] = std::move(map_def);
    }
    if (content["maps"].empty())
        throw std::runtime_error("No map JSON files found in: " + maps_dir.string());
    const auto quests_path = data_dir / "quests.json";
    if (std::filesystem::exists(quests_path)) {
        content["quests"] = read_json_file(quests_path);
    }
    return content;
}

// Asynchronous MongoDB worker pool with per-player FIFO serialization.
class MongoStore {
public:
    using Job = std::function<void(mongoc_collection_t*)>;

    MongoStore(const std::string& uri_string, std::string database, std::size_t threads)
        : database_(std::move(database)) {
        bson_error_t error{};
        uri_.reset(mongoc_uri_new_with_error(uri_string.c_str(), &error));
        if (!uri_) throw std::runtime_error("Invalid MongoDB connection configuration.");
        pool_.reset(mongoc_client_pool_new(uri_.get()));
        if (!pool_) throw std::runtime_error("Could not create MongoDB client pool.");

        // Fail fast on startup if MongoDB is unreachable.
        mongoc_client_t* probe = mongoc_client_pool_pop(pool_.get());
        if (!probe) throw std::runtime_error("Could not acquire MongoDB client.");
        Bson ping;
        BSON_APPEND_INT32(ping.get(), "ping", 1);
        const bool ok = mongoc_client_command_simple(
            probe, database_.c_str(), ping.get(), nullptr, nullptr, nullptr);
        mongoc_client_pool_push(pool_.get(), probe);
        if (!ok) throw std::runtime_error("MongoDB ping failed. Check the server configuration.");

        const std::size_t worker_count = std::clamp<std::size_t>(threads, 1, 16);
        workers_.reserve(worker_count);
        for (std::size_t i = 0; i < worker_count; ++i) {
            workers_.emplace_back([this] { run(); });
        }
    }

    ~MongoStore() { drain(); }

    void enqueue(const std::string& player_id, Job job) {
        {
            std::lock_guard lock(mutex_);
            if (stopping_) return;
            queues_[player_id].push_back(std::move(job));
            if (active_.insert(player_id).second) {
                ready_.push_back(player_id);
            }
        }
        cv_.notify_one();
    }

    void drain() {
        {
            std::lock_guard lock(mutex_);
            if (stopping_) return;
            stopping_ = true;
        }
        cv_.notify_all();
        for (auto& worker : workers_) {
            if (worker.joinable()) worker.join();
        }
        workers_.clear();
    }

private:
    void run() {
        while (true) {
            std::string player_id;
            Job job;
            {
                std::unique_lock lock(mutex_);
                cv_.wait(lock, [this] {
                    return !ready_.empty() || (stopping_ && active_.empty());
                });
                if (ready_.empty()) {
                    if (stopping_ && active_.empty()) break;
                    continue;
                }
                player_id = std::move(ready_.front());
                ready_.pop_front();
                auto& queue = queues_[player_id];
                job = std::move(queue.front());
                queue.pop_front();
            }

            if (mongoc_client_t* client = mongoc_client_pool_pop(pool_.get())) {
                const std::unique_ptr<mongoc_collection_t, decltype(&mongoc_collection_destroy)> records(
                    mongoc_client_get_collection(client, database_.c_str(), "players"),
                    mongoc_collection_destroy);
                try {
                    job(records.get());
                } catch (const std::exception& error) {
                    std::cerr << "MongoDB worker error: " << error.what() << '\n';
                }
                mongoc_client_pool_push(pool_.get(), client);
            } else {
                try {
                    job(nullptr);
                } catch (const std::exception& error) {
                    std::cerr << "MongoDB worker error: " << error.what() << '\n';
                }
            }

            bool notify_all = false;
            bool notify_one = false;
            {
                std::lock_guard lock(mutex_);
                auto it = queues_.find(player_id);
                if (it != queues_.end() && !it->second.empty()) {
                    ready_.push_back(player_id);
                    notify_one = true;
                } else {
                    if (it != queues_.end()) queues_.erase(it);
                    active_.erase(player_id);
                    if (stopping_ && active_.empty()) notify_all = true;
                }
            }
            if (notify_all) cv_.notify_all();
            else if (notify_one) cv_.notify_one();
        }
    }

    MongoDriver mongo_;
    std::string database_;
    std::unique_ptr<mongoc_uri_t, decltype(&mongoc_uri_destroy)> uri_{nullptr, mongoc_uri_destroy};
    std::unique_ptr<mongoc_client_pool_t, decltype(&mongoc_client_pool_destroy)> pool_{
        nullptr, mongoc_client_pool_destroy};

    std::mutex mutex_;
    std::condition_variable cv_;
    std::unordered_map<std::string, std::deque<Job>> queues_;
    std::unordered_set<std::string> active_;
    std::deque<std::string> ready_;
    bool stopping_ = false;
    std::vector<std::thread> workers_;
};
}  // namespace

class Runtime::Impl {
public:
    Impl(const std::string& uri, const std::string& database, const std::filesystem::path& script,
        Post post, std::size_t db_threads)
        : script_(script), store_(uri, database, db_threads), post_(std::move(post)) {
        if (!post_) throw std::runtime_error("Missing async post dispatcher.");
        if (!lua_) throw std::runtime_error("could not open Lua runtime");
        luaL_openlibs(lua_.get());
        auto* state = lua_.get();
        if (luaL_dofile(state, script.string().c_str()) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        const auto content = load_content(script);
        lua_getfield(state, -1, "new");
        bind(state, load_record);
        bind(state, save_record);
        lua_pushcfunction(state, monotonic_clock);
        push_json(state, content);
        if (lua_pcall(state, 4, 1, 0) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        world_ = luaL_ref(state, LUA_REGISTRYINDEX);
        lua_pop(state, 1);
    }

    ~Impl() {
        *alive_ = false;
        store_.drain();
    }

    void action(const char* method, const std::string& id, const Json* data, Callback done) {
        auto* main_state = lua_.get();
        lua_State* co = lua_newthread(main_state);
        const int ref = luaL_ref(main_state, LUA_REGISTRYINDEX);

        auto call = std::make_shared<Call>(Call{co, ref, std::move(done)});
        calls_[co] = call;

        lua_rawgeti(co, LUA_REGISTRYINDEX, world_);
        lua_getfield(co, -1, method);
        lua_insert(co, -2);
        lua_pushlstring(co, id.data(), id.size());
        int count = 2;
        if (data) {
            push_json(co, *data);
            ++count;
        }
        step(call, count);
    }

    Json tick() {
        auto* state = lua_.get();
        StackScope stack(state);
        begin(state, "tick");
        if (lua_pcall(state, 1, 1, 0) != LUA_OK) {
            std::cerr << lua_error_text(state) << '\n';
            return nullptr;
        }
        return read_lua(state, -1);
    }

    Json reload() {
        try {
            const auto content = load_content(script_);
            auto* state = lua_.get();
            StackScope stack(state);
            begin(state, "reload");
            push_json(state, content);
            if (lua_pcall(state, 2, 1, 0) != LUA_OK) {
                std::cerr << "Config reload failed: " << lua_error_text(state) << '\n';
                return nullptr;
            }
            return read_lua(state, -1);
        } catch (const std::exception& error) {
            std::cerr << "Config reload failed: " << error.what() << '\n';
            return nullptr;
        }
    }

    Json snapshot() {
        auto* state = lua_.get();
        StackScope stack(state);
        begin(state, "snapshot");
        if (lua_pcall(state, 1, 1, 0) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        return read_lua(state, -1);
    }

private:
    struct Call {
        lua_State* co = nullptr;
        int ref = LUA_NOREF;
        Callback done;
    };

    void begin(lua_State* state, const char* method) const {
        lua_rawgeti(state, LUA_REGISTRYINDEX, world_);
        lua_getfield(state, -1, method);
        lua_insert(state, -2);
    }

    void bind(lua_State* state, lua_CFunction function) {
        lua_pushlightuserdata(state, this);
        lua_pushcclosure(state, function, 1);
    }

    static Impl& self(lua_State* state) {
        return *static_cast<Impl*>(lua_touserdata(state, lua_upvalueindex(1)));
    }

    void step(const std::shared_ptr<Call>& call, int nargs) {
        int nres = 0;
        const int status = lua_resume(call->co, lua_.get(), nargs, &nres);
        if (status == LUA_YIELD) return;

        Result result{failure("internal_error"), nullptr};
        if (status == LUA_OK) {
            try {
                Json first = nres >= 1 ? read_lua(call->co, -nres) : Json(nullptr);
                Json second = nres >= 2 ? read_lua(call->co, -nres + 1) : Json(nullptr);
                result = {std::move(first), std::move(second)};
            } catch (const std::exception& error) {
                std::cerr << "Lua return decode error: " << error.what() << '\n';
            }
        } else {
            std::cerr << lua_error_text(call->co) << '\n';
        }

        calls_.erase(call->co);
        luaL_unref(lua_.get(), LUA_REGISTRYINDEX, call->ref);
        call->ref = LUA_NOREF;
        if (call->done) call->done(std::move(result));
    }

    static int monotonic_clock(lua_State* state) {
        const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        lua_pushinteger(state, milliseconds);
        return 1;
    }

    static int load_record(lua_State* co) {
        auto& runtime = self(co);
        const char* raw_id = lua_tostring(co, 1);
        const std::string id = raw_id ? raw_id : "";
        auto it = runtime.calls_.find(co);
        if (it == runtime.calls_.end()) {
            lua_pushnil(co);
            lua_pushliteral(co, "store_unavailable");
            return 2;
        }
        auto call = it->second;
        auto alive = runtime.alive_;

        runtime.store_.enqueue(id, [&runtime, alive, call, id](mongoc_collection_t* records) {
            std::optional<Json> loaded;
            bool failed = false;
            try {
                if (!records) throw std::runtime_error("missing collection");
                Bson query;
                BSON_APPEND_UTF8(query.get(), "_id", id.c_str());
                const std::unique_ptr<mongoc_cursor_t, decltype(&mongoc_cursor_destroy)> cursor(
                    mongoc_collection_find_with_opts(records, query.get(), nullptr, nullptr),
                    mongoc_cursor_destroy);
                const bson_t* document = nullptr;
                if (!mongoc_cursor_next(cursor.get(), &document)) {
                    if (mongoc_cursor_error(cursor.get(), nullptr))
                        throw std::runtime_error("find failed");
                } else {
                    const std::unique_ptr<char, decltype(&bson_free)> text(
                        bson_as_relaxed_extended_json(document, nullptr), bson_free);
                    auto record = Json::parse(text.get());
                    record.erase("_id");
                    loaded = std::move(record);
                }
            } catch (const std::exception&) {
                std::cerr << "MongoDB character load failed\n";
                failed = true;
            }

            runtime.post_([&runtime, alive, call, loaded = std::move(loaded), failed]() mutable {
                if (!*alive) return;
                if (failed) {
                    lua_pushnil(call->co);
                    lua_pushliteral(call->co, "store_unavailable");
                    runtime.step(call, 2);
                } else if (loaded) {
                    push_json(call->co, *loaded);
                    runtime.step(call, 1);
                } else {
                    lua_pushnil(call->co);
                    runtime.step(call, 1);
                }
            });
        });

        return lua_yield(co, 0);
    }

    static int save_record(lua_State* co) {
        auto& runtime = self(co);
        const char* raw_id = lua_tostring(co, 1);
        const std::string id = raw_id ? raw_id : "";
        const auto expected = static_cast<std::int64_t>(lua_tointeger(co, 3));
        std::string text;
        try {
            auto record = read_lua(co, 2);
            record["_id"] = id;
            text = record.dump();
        } catch (const std::exception&) {
            std::cerr << "MongoDB character encode failed\n";
            lua_pushboolean(co, false);
            return 1;
        }

        auto it = runtime.calls_.find(co);
        if (it == runtime.calls_.end()) {
            lua_pushboolean(co, false);
            return 1;
        }
        auto call = it->second;
        auto alive = runtime.alive_;

        runtime.store_.enqueue(id, [&runtime, alive, call, id, expected, text = std::move(text)](
                                       mongoc_collection_t* records) {
            bool saved = false;
            try {
                if (!records) throw std::runtime_error("missing collection");
                const std::unique_ptr<bson_t, decltype(&bson_destroy)> document(
                    bson_new_from_json(reinterpret_cast<const uint8_t*>(text.data()), text.size(), nullptr),
                    bson_destroy);
                if (!document) throw std::runtime_error("invalid character document");
                if (expected == 0) {
                    saved = mongoc_collection_insert_one(records, document.get(), nullptr, nullptr, nullptr);
                } else {
                    Bson filter;
                    BSON_APPEND_UTF8(filter.get(), "_id", id.c_str());
                    BSON_APPEND_INT64(filter.get(), "revision", expected);
                    bson_t reply;
                    if (mongoc_collection_replace_one(records, filter.get(), document.get(), nullptr, &reply, nullptr)) {
                        bson_iter_t count;
                        saved = bson_iter_init_find(&count, &reply, "matchedCount")
                            && bson_iter_as_int64(&count) == 1;
                    }
                    bson_destroy(&reply);
                }
            } catch (const std::exception&) {
                std::cerr << "MongoDB character save failed\n";
            }

            runtime.post_([&runtime, alive, call, saved]() {
                if (!*alive) return;
                lua_pushboolean(call->co, saved);
                runtime.step(call, 1);
            });
        });

        return lua_yield(co, 0);
    }

    std::filesystem::path script_;
    MongoStore store_;
    Post post_;
    std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
    std::unique_ptr<lua_State, decltype(&lua_close)> lua_{luaL_newstate(), lua_close};
    int world_ = LUA_NOREF;
    std::unordered_map<lua_State*, std::shared_ptr<Call>> calls_;
};

Runtime::Runtime(const std::string& uri, const std::string& database, const std::filesystem::path& script,
    Post post, std::size_t db_threads)
    : impl_(std::make_unique<Impl>(uri, database, script, std::move(post), db_threads)) {}

Runtime::~Runtime() = default;

void Runtime::join(const std::string& id, Callback done) {
    impl_->action("join", id, nullptr, std::move(done));
}

void Runtime::request(const std::string& id, const Json& message, Callback done) {
    impl_->action("request", id, &message, std::move(done));
}

void Runtime::leave(const std::string& id, LeaveCallback done) {
    impl_->action("leave", id, nullptr, [done = std::move(done)](Result result) {
        const bool saved = result.second.is_boolean() && result.second.get<bool>();
        if (!result.first.is_null() && !saved) std::cerr << "Disconnect checkpoint failed\n";
        if (done) done(std::move(result.first));
    });
}

Runtime::Json Runtime::tick() { return impl_->tick(); }

Runtime::Json Runtime::reload() { return impl_->reload(); }

Runtime::Json Runtime::snapshot() { return impl_->snapshot(); }
