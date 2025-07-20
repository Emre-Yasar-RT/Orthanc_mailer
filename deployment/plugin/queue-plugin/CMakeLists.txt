cmake_minimum_required(VERSION 3.10)
project(QueuePlugin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Include paths
include_directories(
    sdk/OrthancFramework
    sdk/OrthancServer/Plugins/Include/orthanc
)

add_library(QueuePlugin SHARED queueplugin.cpp)

target_compile_definitions(QueuePlugin PRIVATE
    ORTHANC_PLUGIN_NAME="QueuePlugin"
    ORTHANC_PLUGIN_VERSION="1.0"
    HAS_ORTHANC_EXCEPTION=1
)

target_link_libraries(QueuePlugin
    pthread
    dl
    rt
)
