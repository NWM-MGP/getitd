
ARG VERSION=0.1.0
ARG GETITD_VERSION=1.5.17
ARG BASE_IMAGE_VERSION=0.1.0

FROM nma2genomicsprdacr1.azurecr.io/python-3.12:${BASE_IMAGE_VERSION}

ARG VERSION
ARG GETITD_VERSION

LABEL version="${VERSION}"
LABEL description="getITD ${GETITD_VERSION} - FLT3 internal tandem duplication detection on Ubuntu 22.04 and Python 3.12"
LABEL maintainer="bioinformatics-team"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MPLBACKEND=Agg

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --only-binary=:all: \
        numpy==1.26.4 \
        pandas==2.2.3 \
        biopython==1.85 \
        matplotlib==3.9.4 && \
    python3 -m pip check

COPY getitd.py LICENSE /opt/getitd/
COPY anno/ /opt/getitd/anno/

RUN printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'exec python3 /opt/getitd/getitd.py -reference /opt/getitd/anno/amplicon.txt -anno /opt/getitd/anno/amplicon_kayser.tsv "$@"' \
        > /usr/local/bin/getitd && \
    chmod 755 /usr/local/bin/getitd && \
    ln -s /usr/local/bin/getitd /usr/local/bin/getitd.py && \
    PYTHONPATH=/opt/getitd python3 -c "import getitd; assert getitd.__version__ == '${GETITD_VERSION}', 'getITD source version mismatch'" && \
    getitd --help

WORKDIR /opt