#!/bin/bash
set -e

cd "$(dirname "$0")"

PLUGINS=("export-plugin" "queue-plugin" "filesender-plugin" "orthanc-python-plugin")

# Clean up any wrong Python plugin directories first
echo "[INFO] Cleaning up any incorrect Python plugin locations..."
rm -rf python/libOrthancPython.so
rm -rf python/*.so

for plugin in "${PLUGINS[@]}"; do
  echo "build $plugin..."

  cd "$plugin"

  CONTAINER_NAME="${plugin}-builder"
  PLATFORM_OPTION="--platform=linux/amd64"
  
  # Handle different naming for Python plugin
  if [ "$plugin" = "orthanc-python-plugin" ]; then
    OUTPUT_PATH="./libOrthancPython.so"
    SO_NAME="libOrthancPython.so"
    # Use separate Dockerfile for Python plugin
    DOCKERFILE="../Dockerfile.python"
  else
    PLUGIN_NAME_CAMEL=$(echo "$plugin" | sed -E 's/(^|-)([a-z])/\U\2/g')
    OUTPUT_PATH="./lib${PLUGIN_NAME_CAMEL}.so"
    SO_NAME="lib${PLUGIN_NAME_CAMEL}.so"
    # Use normal Dockerfile for other plugins
    DOCKERFILE="../Dockerfile.builder"
  fi
  
  IMAGE_NAME="orthanc-${plugin}"

  docker build $PLATFORM_OPTION -f "$DOCKERFILE" -t "$IMAGE_NAME" .

  docker rm -f "$CONTAINER_NAME" || true
  docker create --name "$CONTAINER_NAME" "$IMAGE_NAME"

  rm -f "$OUTPUT_PATH"
  docker cp "$CONTAINER_NAME:/output/$SO_NAME" "$OUTPUT_PATH" || {
    echo "Plugin $plugin could not be copied"
    docker rm "$CONTAINER_NAME"
    exit 1
  }

  # Verify the file is actually a shared library
  if [ -f "$OUTPUT_PATH" ]; then
    FILE_TYPE=$(file "$OUTPUT_PATH")
    if echo "$FILE_TYPE" | grep -q "shared object"; then
      echo "Plugin $plugin successfully built in $OUTPUT_PATH"
      echo "  File type: shared object ✓"
    else
      echo "WARNING: $OUTPUT_PATH exists but may not be a valid shared library"
      echo "  File type: $FILE_TYPE"
    fi
  else
    echo "Plugin $plugin build did not work"
    exit 1
  fi

  # Clean up container
  docker rm "$CONTAINER_NAME"

  cd ..
done

# Final cleanup: ensure no incorrect Python plugin files exist
echo "[INFO] Final cleanup of incorrect Python plugin locations..."
rm -rf python/libOrthancPython.so
rm -rf python/*.so

echo "[INFO] All plugins built successfully!"
echo "[INFO] Python plugin location: orthanc-python-plugin/libOrthancPython.so"