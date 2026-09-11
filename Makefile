CC ?= cc
CPPFLAGS ?=
CFLAGS ?= -O2
LDFLAGS ?=

RUNNER := bin/ai-usage-pills-runner
RUNNER_BUILD_FLAGS := -std=c17 -Wall -Wextra -Werror -static-pie \
	-Wl,-z,relro,-z,now,-s

RUNNER_SOURCE := native/ai-usage-pills-runner.c
.PHONY: all clean test verify-runner

all: $(RUNNER)

$(RUNNER): $(RUNNER_SOURCE)
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(RUNNER_BUILD_FLAGS) $(LDFLAGS) -o $@ $<

verify-runner: $(RUNNER)
	@copy=$$(mktemp); trap 'rm -f "$$copy"' 0; \
		$(CC) $(CPPFLAGS) $(CFLAGS) $(RUNNER_BUILD_FLAGS) $(LDFLAGS) \
			-o "$$copy" $(RUNNER_SOURCE); \
		cmp $(RUNNER) "$$copy"

test: verify-runner
	./tests/test-runner.sh

clean:
	rm -f $(RUNNER)
