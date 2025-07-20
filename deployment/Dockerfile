FROM jodogne/orthanc-plugins

# Install only necessary dependencies (without orthanc-python package)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        curl \
        libcurl4-openssl-dev \
        libcurl4 \
        p7zip-full \
        unzip \
        python3-venv \
        python3-dev && \
    python3 -m venv /.venv && \
    /.venv/bin/pip install --upgrade pip && \
    /.venv/bin/pip install \
        requests \
        pydicom \
        urllib3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# set pythonpath, for plugins to find
ENV PYTHONPATH=/.venv/lib/python3.11/site-packages

# copy CLI-Tool
COPY switchfilesender/filesender_cli /filesender_cli
COPY switchfilesender/filesender_cli/.filesender /root/.filesender