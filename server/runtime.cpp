#include "runtime.hpp"

#include <mongoc/mongoc.h>
#include <lua.hpp>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string_view>

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
}  // namespace

class Runtime::Impl {
public:
    Impl(const std::string& uri, const std::string& database, const std::filesystem::path& script)
        : client_(mongoc_client_new(uri.c_str()), mongoc_client_destroy),
          records_(client_ ? mongoc_client_get_collection(client_.get(), database.c_str(), "players") : nullptr,
              mongoc_collection_destroy) {
        if (!records_) throw std::runtime_error("Invalid MongoDB connection configuration.");
        Bson ping;
        BSON_APPEND_INT32(ping.get(), "ping", 1);
        if (!mongoc_client_command_simple(client_.get(), database.c_str(), ping.get(), nullptr, nullptr, nullptr))
            throw std::runtime_error("MongoDB ping failed. Check the server configuration.");
        if (!lua_) throw std::runtime_error("could not open Lua runtime");
        luaL_openlibs(lua_.get());
        auto* state = lua_.get();
        if (luaL_dofile(state, script.string().c_str()) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        lua_getfield(state, -1, "new");
        bind(state, load_record);
        bind(state, save_record);
        lua_pushcfunction(state, monotonic_clock);
        if (lua_pcall(state, 3, 1, 0) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        world_ = luaL_ref(state, LUA_REGISTRYINDEX);
        lua_pop(state, 1);
    }

    Result action(const char* method, const std::string* id = nullptr, const Json* data = nullptr) {
        auto* state = lua_.get();
        StackScope stack(state);
        begin(method);
        int count = 1;
        if (id) {
            lua_pushlstring(state, id->data(), id->size());
            ++count;
        }
        if (data) {
            push_json(state, *data);
            ++count;
        }
        if (lua_pcall(state, count, 2, 0) != LUA_OK) {
            std::cerr << lua_error_text(state) << '\n';
            return {failure("internal_error"), false};
        }
        return {read_lua(state, -2), static_cast<bool>(lua_toboolean(state, -1))};
    }

    Json snapshot() {
        auto* state = lua_.get();
        StackScope stack(state);
        begin("snapshot");
        if (lua_pcall(state, 1, 1, 0) != LUA_OK)
            throw std::runtime_error(lua_error_text(state));
        return read_lua(state, -1);
    }

private:
    void begin(const char* method) {
        auto* state = lua_.get();
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

    static int monotonic_clock(lua_State* state) {
        const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        lua_pushinteger(state, milliseconds);
        return 1;
    }

    static int load_record(lua_State* state) {
        try {
            const std::string id = lua_tostring(state, 1);
            Bson query;
            BSON_APPEND_UTF8(query.get(), "_id", id.c_str());
            const std::unique_ptr<mongoc_cursor_t, decltype(&mongoc_cursor_destroy)> cursor(
                mongoc_collection_find_with_opts(self(state).records_.get(), query.get(), nullptr, nullptr),
                mongoc_cursor_destroy);
            const bson_t* document = nullptr;
            if (!mongoc_cursor_next(cursor.get(), &document)) {
                if (mongoc_cursor_error(cursor.get(), nullptr)) throw std::runtime_error("find failed");
                lua_pushnil(state);
            } else {
                const std::unique_ptr<char, decltype(&bson_free)> text(
                    bson_as_relaxed_extended_json(document, nullptr), bson_free);
                auto record = Json::parse(text.get());
                record.erase("_id");
                push_json(state, record);
            }
            return 1;
        } catch (const std::exception&) {
            std::cerr << "MongoDB character load failed\n";
            lua_pushnil(state);
            lua_pushliteral(state, "store_unavailable");
            return 2;
        }
    }

    static int save_record(lua_State* state) {
        bool saved = false;
        try {
            auto* records = self(state).records_.get();
            const std::string id = lua_tostring(state, 1);
            const auto expected = static_cast<std::int64_t>(lua_tointeger(state, 3));
            auto record = read_lua(state, 2);
            record["_id"] = id;
            const auto text = record.dump();
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
                    saved = bson_iter_init_find(&count, &reply, "matchedCount") && bson_iter_as_int64(&count) == 1;
                }
                bson_destroy(&reply);
            }
        } catch (const std::exception&) {
            std::cerr << "MongoDB character save failed\n";
        }
        lua_pushboolean(state, saved);
        return 1;
    }

    MongoDriver mongo_;
    std::unique_ptr<mongoc_client_t, decltype(&mongoc_client_destroy)> client_;
    std::unique_ptr<mongoc_collection_t, decltype(&mongoc_collection_destroy)> records_;
    std::unique_ptr<lua_State, decltype(&lua_close)> lua_{luaL_newstate(), lua_close};
    int world_ = LUA_NOREF;
};

Runtime::Runtime(const std::string& uri, const std::string& database, const std::filesystem::path& script)
    : impl_(std::make_unique<Impl>(uri, database, script)) {}
Runtime::~Runtime() = default;
Runtime::Result Runtime::join(const std::string& id) { return impl_->action("join", &id); }
Runtime::Result Runtime::request(const std::string& id, const Json& message) {
    return impl_->action("request", &id, &message);
}
bool Runtime::leave(const std::string& id) {
    const auto [changed, saved] = impl_->action("leave", &id);
    if (changed.is_boolean() && changed.get<bool>() && !saved)
        std::cerr << "Disconnect checkpoint failed\n";
    return changed.is_boolean() && changed.get<bool>();
}
bool Runtime::tick() {
    auto changed = impl_->action("tick").first;
    return changed.is_boolean() && changed.get<bool>();
}
Runtime::Json Runtime::snapshot() { return impl_->snapshot(); }
