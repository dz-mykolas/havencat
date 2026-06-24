APP := apps
FVM_VERSION ?= stable
DEVICE ?= web-server
WEB_HOST ?= 0.0.0.0
WEB_PORT ?= 8080
SERVE_PORT ?= 8088

FLUTTER := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/flutter
DART := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/dart

RUN_ARGS := -d $(DEVICE)

ifeq ($(DEVICE),web-server)
RUN_ARGS += --web-hostname $(WEB_HOST) --web-port $(WEB_PORT)
# In the browser, LLM calls go through the local reverse proxy (CORS). Point
# the web build at it; run `make server` in another terminal alongside this.
RUN_ARGS += --dart-define=LLM_PROXY=http://localhost:$(SERVE_PORT)/proxy
endif

.PHONY: install run run-profile run-release server serve rust check format build-play build-apk build-ios build-web build-desktop clean

# Install the pinned Flutter SDK and project dependencies.
install:
	fvm install $(FVM_VERSION)
	cd $(APP) && $(FLUTTER) pub get

# Run the app in debug mode with hot reload.
run:
	cd $(APP) && $(FLUTTER) run $(RUN_ARGS)

# Run the app in profile mode for performance testing.
run-profile:
	cd $(APP) && $(FLUTTER) run $(RUN_ARGS) --profile

# Run the app in release mode for production-like testing.
run-release:
	cd $(APP) && $(FLUTTER) run $(RUN_ARGS) --release

# Format, analyze, and run normal tests.
check:
	$(DART) format --set-exit-if-changed .
	$(FLUTTER) analyze
	$(FLUTTER) test

# Format code.
format:
	$(DART) format .

# Build Android App Bundle for Play Store.
build-play:
	cd $(APP) && $(FLUTTER) build appbundle

# Build Android APK for sideload/manual testing.
build-apk:
	cd $(APP) && $(FLUTTER) build apk --release

# Build iOS IPA. Run on macOS only.
build-ios:
	cd $(APP) && $(FLUTTER) build ipa

# Build web app.
build-web:
	cd $(APP) && $(FLUTTER) build web --dart-define=LLM_PROXY=/proxy

# Self-host the web build: one Dart process serves the app + a same-origin
# LLM reverse proxy (so the browser isn't blocked by CORS). Builds first.
serve: build-web
	cd $(APP) && PORT=$(SERVE_PORT) $(DART) run bin/serve.dart

# Build the Rust crate (cdylib) that the server + native apps load via FFI.
# `dart run` and `flutter run` don't trigger Cargokit for the server path,
# so this must run first whenever Rust code changes.
rust:
	cd rust && cargo build --release

# Run the local server: LLM reverse proxy (CORS bypass) + web retrieval API
# (Rust-backed search/fetch/cache). Use this in a second terminal next to
# `make run` for hot-reload web development against real providers.
server: rust
	cd $(APP) && PORT=$(SERVE_PORT) $(DART) run bin/serve.dart

# Build desktop app for the current OS.
build-desktop:
	cd $(APP) && \
	if [ "$$(uname)" = "Darwin" ]; then $(FLUTTER) build macos; \
	elif [ "$$(uname)" = "Linux" ]; then $(FLUTTER) build linux; \
	else $(FLUTTER) build windows; fi

# Remove Flutter build outputs.
clean:
	cd $(APP) && $(FLUTTER) clean