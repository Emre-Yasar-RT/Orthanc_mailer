FROM jodogne/orthanc:latest

# Install only required dependencies + JsonCpp runtime library
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        curl \
        libcurl4-openssl-dev \
        libcurl4 \
        p7zip-full \
        unzip \
        python3-venv \
        python3-dev \
        libjsoncpp25 \
        libboost-all-dev && \
    python3 -m venv /.venv && \
    /.venv/bin/pip install --upgrade pip && \
    /.venv/bin/pip install \
        requests \
        pydicom \
        urllib3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set PYTHONPATH so plugins can locate it
ENV PYTHONPATH=/.venv/lib/python3.11/site-packages

# Copy CLI-Tool
COPY switchfilesender/filesender_cli /filesender_cli
COPY switchfilesender/filesender_cli/.filesender /root/.filesender