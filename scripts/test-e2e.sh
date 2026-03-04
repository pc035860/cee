#!/bin/bash
set -euo pipefail

# =============================================================================
# test-e2e.sh - Cee macOS App E2E Test Runner
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="${PROJECT_DIR}/Cee.xcodeproj"
SCHEME="Cee"
DESTINATION="platform=macOS,arch=arm64"
RESULT_BUNDLE="${PROJECT_DIR}/TestResults.xcresult"
LOG_FILE="${PROJECT_DIR}/xcodebuild.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    if [ -d "$RESULT_BUNDLE" ]; then rm -rf "$RESULT_BUNDLE"; fi
}

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v xcodebuild &> /dev/null; then
        error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    if [ ! -d "$PROJECT_FILE" ]; then
        warn "Xcode project not found. Running xcodegen..."
        if command -v xcodegen &> /dev/null; then
            (cd "$PROJECT_DIR" && xcodegen generate)
        else
            error "Neither .xcodeproj nor xcodegen found."
            exit 1
        fi
    fi

    info "Prerequisites OK."
}

run_tests() {
    info "Running E2E tests..."
    info "  Scheme:      $SCHEME"
    info "  Destination: $DESTINATION"
    info "  Results:     $RESULT_BUNDLE"

    local exit_code=0

    xcodebuild test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -parallel-testing-enabled NO \
        2>&1 | tee "$LOG_FILE" || exit_code=$?

    return $exit_code
}

print_summary() {
    if [ ! -d "$RESULT_BUNDLE" ]; then
        warn "No result bundle found."
        return
    fi

    info "=== Test Summary ==="
    if xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null; then
        :
    elif xcrun xcresulttool get object --legacy --format json --path "$RESULT_BUNDLE" 2>/dev/null | head -50; then
        :
    else
        warn "Could not extract summary from xcresult."
    fi
}

main() {
    info "Cee E2E Test Runner"
    info "==================="

    cleanup
    check_prerequisites

    local exit_code=0
    run_tests || exit_code=$?

    echo ""
    print_summary

    echo ""
    if [ $exit_code -eq 0 ]; then
        info "=== ALL TESTS PASSED ==="
    else
        error "=== TESTS FAILED (exit code: $exit_code) ==="
    fi

    info "Result bundle: $RESULT_BUNDLE"
    info "Build log:     $LOG_FILE"

    exit $exit_code
}

main "$@"
