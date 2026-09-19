set dotenv-load

derived_data := ".build/xcode-derived"
build_configuration := "Release"
app_bundle := derived_data / "Build/Products" / build_configuration / "Runlet.app"

lint:
    swiftlint lint Sources

lint-fix:
    swiftlint lint --fix Sources

format:
    swift format --recursive --in-place Sources

format-check:
    swift format lint --recursive Sources

build:
    xcodebuild -project Runlet.xcodeproj \
        -scheme Runlet \
        -configuration '{{ build_configuration }}' \
        -derivedDataPath '{{ derived_data }}' \
        -allowProvisioningUpdates \
        "CODE_SIGN_STYLE=${CODE_SIGN_STYLE:-Automatic}" \
        "CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}" \
        "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}" \
        ONLY_ACTIVE_ARCH=YES build

clean:
    rm -rf .build

run: build
    @osascript -e 'quit app "Runlet"' 2>/dev/null || true
    @n=0; while pgrep -x Runlet >/dev/null 2>&1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
    @touch '{{ app_bundle }}'
    @'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister' -f '{{ app_bundle }}'
    @open '{{ app_bundle }}'

install: build
    @rm -rf ~/Applications/Runlet.app
    @cp -R '{{ app_bundle }}' ~/Applications/Runlet.app
    @echo 'Installed to ~/Applications/Runlet.app'
