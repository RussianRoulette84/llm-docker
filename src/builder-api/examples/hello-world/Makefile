# Minimal Makefile demonstrating the builder-api happy path.
# `make` with no args prints a banner; `make --fast` and `make --clean`
# match the whitelisted args in .builder-api.toml so the server will accept
# them. They all route to the `all` target here for simplicity.

.PHONY: all --fast --clean

all --fast --clean:
	@mkdir -p logs
	@echo "hello-world build ran at $$(date)" | tee -a logs/build.log
	@echo "args: $(MAKECMDGOALS)" | tee -a logs/build.log
	@sleep 1
	@echo "done." | tee -a logs/build.log
