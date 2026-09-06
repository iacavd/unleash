.PHONY: lint test build clean ci ci-full check fmt-check

lint:
	shellcheck -S warning unleash lib/*.sh 2>/dev/null || { brew install shellcheck && shellcheck -S warning unleash lib/*.sh; }
	bash -n unleash
	@for f in lib/*.sh; do bash -n "$$f" || exit 1; done
	@echo "All files pass lint"

test:
	bats tests/*.bats

build:
	./examples/build-standalone.sh

clean:
	rm -f unleash-standalone.sh

check: lint test
	@echo "All checks passed"

fmt-check:
	@echo "=== Tab/Space Consistency ==="
	@for f in unleash lib/*.sh; do \
	  mixed=$$(grep -nP '^ +\t|\t +' "$$f" 2>/dev/null | head -3); \
	  if [ -n "$$mixed" ]; then \
	    echo "  WARN: $$f has mixed indent"; \
	    echo "$$mixed" | sed 's/^/    /'; \
	  fi; \
	done
	@echo "=== Trailing Whitespace ==="
	@for f in unleash lib/*.sh; do \
	  trail=$$(grep -nE '\s+$$' "$$f" 2>/dev/null | head -3); \
	  if [ -n "$$trail" ]; then \
	    echo "  WARN: $$f has trailing whitespace"; \
	  fi; \
	done
	@echo "Format check done"

ci:
	@echo "=== ShellCheck ===" && \
	  for f in unleash lib/*.sh examples/*.sh scripts/*.sh; do \
	    [ -f "$$f" ] || continue; \
	    echo "  $$f"; shellcheck -S warning "$$f" || exit 1; \
	  done && \
	  echo "=== Bash Syntax ===" && \
	  for f in unleash lib/*.sh examples/*.sh scripts/*.sh; do \
	    [ -f "$$f" ] || continue; \
	    bash -n "$$f" || exit 1; \
	  done && \
	  echo "=== All lint checks passed ==="

ci-full: ci test
	@echo "=== Full CI passed ==="
