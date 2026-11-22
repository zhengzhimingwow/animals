#pragma once

#include <cstddef>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <nlohmann/json.hpp>

class Runtime {
public:
    using Json = nlohmann::json;
    // First is the unicast reply (or event for leave); second is the optional delta broadcast event (or saved flag for leave).
    using Result = std::pair<Json, Json>;
    using Callback = std::function<void(Result)>;
    using LeaveCallback = std::function<void(Json)>;
    using Post = std::function<void(std::function<void()>)>;

    Runtime(const std::string& uri, const std::string& database, const std::filesystem::path& script,
        Post post, std::size_t db_threads = 4);
    ~Runtime();

    void join(const std::string& id, Callback done);
    void request(const std::string& id, const Json& message, Callback done);
    void leave(const std::string& id, LeaveCallback done);
    Json tick();
    Json reload();
    Json snapshot();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
