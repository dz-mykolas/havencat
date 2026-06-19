APP := apps
FVM_VERSION ?= stable
DEVICE ?= web-server
WEB_HOST ?= 0.0.0.0
WEB_PORT ?= 8080

FLUTTER := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/flutter
DART := $(HOME)/fvm/versions/$(FVM_VERSION)/bin/dart

RUN_ARGS := -d $(DEVICE)

ifeq ($(DEVICE),web-server)
RUN_ARGS += --web-hostname $(WEB_HOST) --web-port $(WEB_PORT)
endif

.PHONY: install run run-profile run-release check format build-play build-apk build-ios build-web build-desktop clean

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
	cd $(APP) && $(FLUTTER) build web

# Build desktop app for the current OS.
build-desktop:
	cd $(APP) && \
	if [ "$$(uname)" = "Darwin" ]; then $(FLUTTER) build macos; \
	elif [ "$$(uname)" = "Linux" ]; then $(FLUTTER) build linux; \
	else $(FLUTTER) build windows; fi

# Remove Flutter build outputs.
clean:
	cd $(APP) && $(FLUTTER) clean