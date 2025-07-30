cmake_minimum_required(VERSION 3.10)
project(FilesenderPlugin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(Boost_USE_STATIC_LIBS ON)
set(Boost_USE_STATIC_RUNTIME ON)
find_package(Boost REQUIRED COMPONENTS thread)

include_directories(
    sdk/OrthancFramework
    sdk/OrthancServer/Plugins/Include/orthanc
    sdk/jsoncpp/include
    sdk/pugixml
    ${Boost_INCLUDE_DIRS}
)

# JSONCPP static
file(GLOB JSONCPP_SOURCES "sdk/jsoncpp/src/lib_json/*.cpp")
add_library(jsoncpp STATIC ${JSONCPP_SOURCES})
set_target_properties(jsoncpp PROPERTIES POSITION_INDEPENDENT_CODE ON)

# PUGIXML
add_library(pugixml STATIC sdk/pugixml/src/pugixml.cpp)
set_target_properties(pugixml PROPERTIES POSITION_INDEPENDENT_CODE ON)

# build plugin
add_library(FilesenderPlugin MODULE filesender.cpp)

target_compile_definitions(FilesenderPlugin PRIVATE
    ORTHANC_PLUGIN_NAME="FilesenderPlugin"
    ORTHANC_PLUGIN_VERSION="1.0"
    HAS_ORTHANC_EXCEPTION=1
)

target_link_libraries(FilesenderPlugin
    jsoncpp
    pugixml
    ${Boost_LIBRARIES}
    pthread
)

set_target_properties(FilesenderPlugin PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY /output
)
