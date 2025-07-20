#!/bin/bash
set -e

cd "$(dirname "$0")"

PLUGINS=("export-plugin" "queue-plugin" "filesender-plugin")

for plugin in "${PLUGINS[@]}"; do
  echo "build $plugin..."

  cd "$plugin"

  CONTAINER_NAME="${plugin}-builder"
  PLATFORM_OPTION="--platform=linux/amd64"
  PLUGIN_NAME_CAMEL=$(echo "$plugin" | sed -E 's/(^|-)([a-z])/\U\2/g')
  OUTPUT_PATH="./lib${PLUGIN_NAME_CAMEL}.so"
  IMAGE_NAME="orthanc-${plugin}"

  docker build $PLATFORM_OPTION -f ../Dockerfile.builder -t "$IMAGE_NAME" .

  docker rm -f "$CONTAINER_NAME" || true
  docker create --name "$CONTAINER_NAME" "$IMAGE_NAME"

  rm -f "$OUTPUT_PATH"
  docker cp "$CONTAINER_NAME:/output/lib${PLUGIN_NAME_CAMEL}.so" "$OUTPUT_PATH" || {
    echo "Plugin $plugin could not be copied"
    docker rm "$CONTAINER_NAME"
    exit 1
  }


  if [ -f "$OUTPUT_PATH" ]; then
    echo "Plugin $plugin successfully build in $OUTPUT_PATH"
  else
    echo "Plugin $plugin build did not work"
    exit 1
  fi

  cd ..
done
