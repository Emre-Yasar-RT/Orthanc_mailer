FROM buildpack-deps:22.04

# install system packages
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake g++ make wget unzip bzip2 build-essential \
    libdcmtk-dev git mercurial \
    && rm -rf /var/lib/apt/lists/*

# install Boost 1.74.0
RUN wget https://archives.boost.io/release/1.74.0/source/boost_1_74_0.tar.bz2 && \
    tar -xjf boost_1_74_0.tar.bz2 && \
    cd boost_1_74_0 && ./bootstrap.sh --with-libraries=thread && \
    ./b2 cxxflags="-fPIC" link=static runtime-link=static install && \
    cd .. && rm -rf boost_1_74_0 boost_1_74_0.tar.bz2

# working directory
WORKDIR /plugin

# copy projectfiles
COPY . .

# Orthanc SDK
RUN mkdir -p sdk && \
    hg clone https://orthanc.uclouvain.be/hg/orthanc sdk/orthanc && \
    mv sdk/orthanc/OrthancFramework sdk/ && \
    mv sdk/orthanc/OrthancServer sdk/ && \
    rm -rf sdk/orthanc

# binding jsoncpp
RUN git clone --depth 1 https://github.com/open-source-parsers/jsoncpp.git sdk/jsoncpp

# binding pugixml
RUN git clone --depth 1 https://github.com/zeux/pugixml.git sdk/pugixml

# Fixes for Orthanc SDK (filesystem-compatibility)
RUN sed -i 's/return p.filename();/return p.filename().string();/' sdk/OrthancFramework/Sources/FileStorage/FilesystemStorage.cpp || true && \
    sed -i 's/std::string f = it->path().filename();/std::string f = it->path().filename().string();/' sdk/OrthancFramework/Sources/HttpServer/FilesystemHttpHandler.cpp || true

# Build both plugins
RUN cmake -S . -B build && cmake --build build

# save .so-files
RUN mkdir -p /output && \
    find build -name 'lib*.so' -exec cp {} /output/ \;

# Cleanup
RUN rm -rf sdk/

CMD ["sleep", "infinity"]
