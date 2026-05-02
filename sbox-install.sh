#!/bin/bash

# sbox-tool: Bootstrap-style compiler for s&box on Linux
set -e

IMAGE_NAME="sbox-public-builder"
BASE_IMAGE_NAME="sbox-public-base"

show_help() {
    echo "sbox-tool - s&box Linux Bootstrap Compiler"
    echo ""
    echo "Usage:"
    echo "  $0 [command] [dir]"
    echo ""
    echo "Commands:"
    echo "  compile    Full build (engine -> shaders -> content)"
    echo "  engine     Compile only the engine"
    echo "  shaders    Compile only the shaders"
    echo "  content    Compile only the content"
    echo "  shell      Open a shell in the build environment"
    echo ""
    echo "Examples:"
    echo "  $0 compile ~/sbox-public"
    echo "  $0 engine ."
}

detect_engine() {
    if command -v docker >/dev/null 2>&1; then echo "docker";
    elif command -v podman >/dev/null 2>&1; then echo "podman";
    fi
}

# --- Initialization ---
ENGINE=$(detect_engine)
if [ -z "$ENGINE" ]; then echo "Error: No container engine found."; exit 1; fi

COMMAND=$1
BUILD_DIR="${2:-$(pwd)}"

if [[ "$BUILD_DIR" == ~* ]]; then BUILD_DIR="${BUILD_DIR/\~/$HOME}"; fi
if [ ! -d "$BUILD_DIR" ]; then echo "Error: Directory not found: $BUILD_DIR"; exit 1; fi
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

build_image() {
    # Phase 1: Build the base image (apt installs only — no Wine execution, no socket calls)
    echo "----------------------------------------"
    echo "==> Phase 1/2: Building base image (apt packages)"
    echo "----------------------------------------"
    $ENGINE build -t "$BASE_IMAGE_NAME" "$SCRIPT_DIR"

    # Phase 2: Run a privileged container to do all Wine setup, then commit as final image
    echo "----------------------------------------"
    echo "==> Phase 2/2: Wine setup (privileged container)"
    echo "----------------------------------------"
    SETUP_CONTAINER="sbox-wine-setup-$$"

    $ENGINE run --privileged --name "$SETUP_CONTAINER" \
        -e WINEPREFIX=/wine \
        -e WINEARCH=win64 \
        -e DISPLAY=:0 \
        -e WINEDEBUG=-all \
        "$BASE_IMAGE_NAME" \
        /bin/bash -c '
            set -e

            echo "==> Initialising Wine prefix..."
            xvfb-run -a -s "-screen 0 1024x768x24" wineboot --init
            wineserver --wait

            echo "==> Installing .NET SDK x64..."
            wget -q https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.203/dotnet-sdk-10.0.203-win-x64.exe
            xvfb-run -a -s "-screen 0 1024x768x24" wine dotnet-sdk-10.0.203-win-x64.exe /install /quiet
            rm dotnet-sdk-10.0.203-win-x64.exe

            echo "==> Installing .NET SDK x86..."
            wget -q https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.203/dotnet-sdk-10.0.203-win-x86.exe
            xvfb-run -a -s "-screen 0 1024x768x24" wine dotnet-sdk-10.0.203-win-x86.exe /install /quiet
            rm dotnet-sdk-10.0.203-win-x86.exe

            echo "==> Installing winetricks components (powershell cmake mingw 7zip cabinet)..."
            xvfb-run -a -s "-screen 0 1024x768x24" winetricks -q powershell cmake mingw 7zip cabinet

            echo "==> Installing winetricks components (dxvk etc)..."
            xvfb-run -a -s "-screen 0 1024x768x24" winetricks -q d3dxof dxdiag dxvk dxvk_async dxvk_nvapi

            echo "==> Installing Git for Windows..."
            wget -q https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/Git-2.52.0-64-bit.tar.bz2
            mkdir -p /wine/drive_c/Git
            tar xjf Git-2.52.0-64-bit.tar.bz2 -C /wine/drive_c/Git
            rm Git-2.52.0-64-bit.tar.bz2
            ln -s /wine/drive_c/Git/bin/git.exe /wine/drive_c/MinGW/bin/git.exe

            echo "==> Cloning sbox-public..."
            mkdir -p /root/sbox
            git clone --depth 1 https://github.com/Facepunch/sbox-public.git /root/sbox

            echo "==> Configuring git safe.directory for Wine..."
            # Wine maps /root/sbox as Z:/root/sbox — mark it safe globally in the Wine git config
            WINE_GITCONFIG="/wine/drive_c/users/root/AppData/Roaming/Git/config"
            mkdir -p "$(dirname "$WINE_GITCONFIG")"
            cat >> "$WINE_GITCONFIG" << 'GITCFG'
[safe]
	directory = Z:/root/sbox
	directory = *
GITCFG

            echo "==> Wine setup complete."
        '

    echo "----------------------------------------"
    echo "==> Committing final image as $IMAGE_NAME..."
    echo "----------------------------------------"
    $ENGINE commit \
        --change 'ENV WINEPREFIX=/wine' \
        --change 'ENV WINEARCH=win64' \
        --change 'ENV DISPLAY=:0' \
        --change 'WORKDIR /root/sbox' \
        "$SETUP_CONTAINER" "$IMAGE_NAME"

    $ENGINE rm "$SETUP_CONTAINER"
    $ENGINE rmi "$BASE_IMAGE_NAME" 2>/dev/null || true

    echo "========================================"
    echo "Build environment ready: $IMAGE_NAME"
    echo "========================================"
}

if ! $ENGINE image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Setting up build environment..."
    build_image
fi

# Function to run the build tool inside the container
run_build() {
    local task=$1
    local task_label=$2
    local extra_args=""

    # Only the main 'build' task uses --config
    if [ "$task" == "build" ]; then
        extra_args="--config Developer"
    fi

    echo "----------------------------------------"
    echo "==> $task_label"
    echo "----------------------------------------"
    $ENGINE run --rm -t --security-opt seccomp=unconfined \
        -v "$BUILD_DIR:/root/sbox" \
        -e WINEDEBUG=-all \
        -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        "$IMAGE_NAME" \
        /bin/bash -c "cd /root/sbox && xvfb-run -a -s '-screen 0 1024x768x24' wine dotnet run --project ./engine/Tools/SboxBuild/SboxBuild.csproj -- $task $extra_args 2>&1"
}

fix_perms() {
    echo ""
    echo "Fixing file permissions..."
    $ENGINE run --rm --security-opt seccomp=unconfined \
        -v "$BUILD_DIR:/root/sbox" \
        "$IMAGE_NAME" chown -R $(id -u):$(id -g) /root/sbox
}

# --- Execution Logic ---
case "$COMMAND" in
    compile|all)
        echo "Starting Full Build for: $BUILD_DIR"
        run_build "build" "Step 1/3: Engine"
        run_build "build-shaders" "Step 2/3: Shaders"
        run_build "build-content" "Step 3/3: Content"
        fix_perms
        echo "========================================"
        echo "Full build complete!"
        ;;
    engine)
        run_build "build" "Engine Build"
        fix_perms
        ;;
    shaders)
        run_build "build-shaders" "Shader Build"
        fix_perms
        ;;
    content)
        run_build "build-content" "Content Build"
        fix_perms
        ;;
    shell)
        echo "Opening build shell in: $BUILD_DIR"
        $ENGINE run -it --rm --security-opt seccomp=unconfined \
            -v "$BUILD_DIR:/root/sbox" \
            -e WINEDEBUG=-all \
            "$IMAGE_NAME" /bin/bash
        fix_perms
        ;;
    help|*)
        show_help
        ;;
esac
