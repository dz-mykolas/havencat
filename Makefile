APP := apps
FVM_VERSION ?= stable
DEVICE ?= web-server
WEB_HOST ?= 0.0.0.0
WEB_PORT ?= 8080
SERVE_PORT ?= 8088
DIST_DIR ?= dist
ANDROID_DIST := $(DIST_DIR)/android

FLUTTER := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/flutter
DART := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/dart

RUN_ARGS := -d $(DEVICE)

# Load `.env` (if present) into the make environment so targets like `server`
# and `run` pick up PORT/LOG_LEVEL/etc. Shell env vars still
# win over `.env` values. Lines starting with `#` and blank lines are skipped.
-include .env
# Export so subprocesses (dart run, flutter run) inherit them as shell env vars.
export PORT HOST LOG_LEVEL RUST_LOG

ifeq ($(DEVICE),web-server)
RUN_ARGS += --web-hostname $(WEB_HOST) --web-port $(WEB_PORT)
# In the browser, LLM calls go through the local reverse proxy (CORS). Point
# the web build at it; run `make server` in another terminal alongside this.
RUN_ARGS += --dart-define=LLM_PROXY=http://localhost:$(SERVE_PORT)/proxy
# Flutter apps can't read shell env vars at runtime, so forward the vars they
# need via --dart-define (sourced from `.env` or shell). Each is only added
# when set, so unset vars keep their in-code defaults.
ifdef LOG_LEVEL
RUN_ARGS += --dart-define=LOG_LEVEL=$(LOG_LEVEL)
endif
ifdef APP_NAME
RUN_ARGS += --dart-define=APP_NAME=$(APP_NAME)
endif
ifdef CODEX_CLIENT_VERSION
RUN_ARGS += --dart-define=CODEX_CLIENT_VERSION=$(CODEX_CLIENT_VERSION)
endif
endif

.PHONY: install run run-profile run-release server rust check format build-play build-apk build-apk-arm64 build-apk-all build-ios build-desktop clean

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

# Build an Android App Bundle for Google Play.
build-play:
	cd $(APP) && $(FLUTTER) build appbundle --release
	mkdir -p $(ANDROID_DIST)
	cp $(APP)/build/app/outputs/bundle/release/app-release.aab $(ANDROID_DIST)/

# Build one universal APK that supports every Flutter Android architecture.
build-apk:
	cd $(APP) && $(FLUTTER) build apk --release
	mkdir -p $(ANDROID_DIST)
	cp $(APP)/build/app/outputs/flutter-apk/app-release.apk $(ANDROID_DIST)/

# Build one smaller ARM64 APK for modern physical Android phones.
build-apk-arm64:
	cd $(APP) && $(FLUTTER) build apk --release --target-platform android-arm64 --split-per-abi
	mkdir -p $(ANDROID_DIST)
	cp $(APP)/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk $(ANDROID_DIST)/

# Build smaller APKs for every supported Android architecture in one pass.
build-apk-all:
	cd $(APP) && $(FLUTTER) build apk --release --split-per-abi
	mkdir -p $(ANDROID_DIST)
	cp $(APP)/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk $(ANDROID_DIST)/
	cp $(APP)/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk $(ANDROID_DIST)/
	cp $(APP)/build/app/outputs/flutter-apk/app-x86_64-release.apk $(ANDROID_DIST)/

# Build iOS IPA. Run on macOS only.
build-ios:
	cd $(APP) && $(FLUTTER) build ipa

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
	rm -rf $(DIST_DIR)
