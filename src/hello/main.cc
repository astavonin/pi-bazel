#include <print>

#include "src/hello/hello.h"
#include "src/hello/sentinel.h"

int main() {
  auto greeting = hello::Greet("pi");
  if (!greeting.has_value()) {
    return 1;
  }
  std::println("{}", *greeting);
  std::println("{}", hello::kSentinel);
  return 0;
}
