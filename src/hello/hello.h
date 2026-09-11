#pragma once

#include <expected>
#include <flat_map>
#include <string>
#include <string_view>

namespace hello {

enum class GreetingError {
  kUnknownAudience,
  kEmptyAudience,
};

// Returns a greeting for `audience`, or kUnknownAudience if it is not a
// KnownAudiences() key, or kEmptyAudience if `audience` is empty.
std::expected<std::string, GreetingError> Greet(std::string_view audience);

// Audiences keyed by name; std::flat_map keeps them sorted by key.
std::flat_map<std::string, std::string> KnownAudiences();

}  // namespace hello
