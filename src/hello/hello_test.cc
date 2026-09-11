// Framework-free: no test dependency is declared yet. Returns non-zero if any
// check fails.
#include "src/hello/hello.h"

#include <cstdio>
#include <string>

namespace {

int failures = 0;

void Check(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

}  // namespace

int main() {
  // std::expected error path: an audience absent from KnownAudiences() must
  // yield kUnknownAudience, not a plausible-looking greeting. error() is only
  // engaged when has_value() is false, so the second check is gated on it.
  auto missing = hello::Greet("nobody");
  Check(!missing.has_value(), "Greet(\"nobody\") should fail");
  if (!missing.has_value()) {
    Check(missing.error() == hello::GreetingError::kUnknownAudience,
          "Greet(\"nobody\") should fail with kUnknownAudience");
  }

  // A distinct error from an unrecognized audience, so the error path is not
  // a single always-reachable enumerator.
  auto empty = hello::Greet("");
  Check(!empty.has_value(), "Greet(\"\") should fail");
  if (!empty.has_value()) {
    Check(empty.error() == hello::GreetingError::kEmptyAudience,
          "Greet(\"\") should fail with kEmptyAudience");
  }

  // Success path too, so a Greet() that always fails does not pass the
  // checks above vacuously. The exact string is asserted, not just presence.
  auto known = hello::Greet("pi");
  Check(known.has_value(), "Greet(\"pi\") should succeed");
  if (known.has_value()) {
    Check(*known == "Hello, Raspberry Pi, pi!",
          "Greet(\"pi\") should return the exact greeting");
  }

  // std::flat_map iteration order: sorted by key, not insertion order.
  auto audiences = hello::KnownAudiences();
  std::string previous_key;
  bool first = true;
  for (const auto& [key, value] : audiences) {
    if (!first) {
      Check(previous_key < key, "flat_map keys should be strictly ascending");
    }
    previous_key = key;
    first = false;
  }
  Check(audiences.size() == 3, "KnownAudiences should have 3 entries");

  return failures == 0 ? 0 : 1;
}
