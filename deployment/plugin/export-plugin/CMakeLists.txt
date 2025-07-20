cmake_minimum_required(VERSION 3.10)
project(ExportPlugin)

set(CMAKE_CXX_STANDARD 17)

set(Boost_USE_STATIC_LIBS ON)
set(Boost_USE_STATIC_RUNTIME ON)
find_package(Boost REQUIRED COMPONENTS thread)

# Find libcurl
find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

include_directories(
    sdk/OrthancFramework
    sdk/OrthancServer/Plugins/Include/orthanc
    sdk/jsoncpp/include
    sdk/pugixml
    ${Boost_INCLUDE_DIRS}
    ${CURL_INCLUDE_DIRS}
)

file(GLOB JSONCPP_SOURCES "sdk/jsoncpp/src/lib_json/*.cpp")
add_library(jsoncpp STATIC ${JSONCPP_SOURCES})
set_target_properties(jsoncpp PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(pugixml STATIC sdk/pugixml/src/pugixml.cpp)
set_target_properties(pugixml PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(ExportPlugin SHARED
    exportplugin.cpp
)

target_compile_definitions(ExportPlugin PRIVATE
    ORTHANC_PLUGIN_NAME="ExportPlugin"
    ORTHANC_PLUGIN_VERSION="1.1"
    HAS_ORTHANC_EXCEPTION=1
)

target_link_libraries(ExportPlugin
    jsoncpp
    pugixml
    ${Boost_LIBRARIES}
    ${CURL_LIBRARIES}
    pthread
)

# Set compiler flags for libcurl
target_compile_options(ExportPlugin PRIVATE ${CURL_CFLAGS_OTHER})