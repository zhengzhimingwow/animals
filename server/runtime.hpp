#pragma once

#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <nlohmann/json.hpp>

class Runtime {
public:
    using Json = nlohmann::json;
    using Result = std::pair<Json, bool>;

    Runtime(const std::string& uri, const std::string& database, const std::filesystem::path& script);
    ~Runtime();
    Result join(const std::string& id);
    Result request(const std::string& id, const Json& message);
    bool leave(const std::string& id);
    bool tick();
    Json snapshot();

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
