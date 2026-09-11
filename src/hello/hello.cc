#include "src/hello/hello.h"

#include <utility>

namespace hello {

std::flat_map<std::string, std::string> KnownAudiences() {
  // Inserted out of alphabetical order on purpose: std::flat_map sorts by
  // key regardless of insertion order, which is what hello_test.cc checks.
  return std::flat_map<std::string, std::string>{
      {"world", "Hello"},
      {"aarch64", "Cross-compiled hello"},
      {"pi", "Hello, Raspberry Pi"},
  };
}

std::expected<std::string, GreetingError> Greet(std::string_view audience) {
  if (audience.empty()) {
    return std::unexpected(GreetingError::kEmptyAudience);
  }
  auto audiences = KnownAudiences();
  auto it = audiences.find(std::string(audience));
  if (it == audiences.end()) {
    return std::unexpected(GreetingError::kUnknownAudience);
  }
  return it->second + ", " + std::string(audience) + "!";
}

}  // namespace hello
