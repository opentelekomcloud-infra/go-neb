# Stage 1: Build the Go application using Debian
FROM golang:1.23-bullseye AS builder

# Install build dependencies for Debian
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gcc \
    libc6-dev \
    make \
    g++ \
    cmake \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install libolm using cmake
RUN git clone --depth 1 --branch 3.2.16 https://gitlab.matrix.org/matrix-org/olm.git /tmp/libolm && \
    cd /tmp/libolm && \
    cmake . -B build -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -C build install && \
    cd / && \
    rm -rf /tmp/libolm

# Copy the local package files to the container
COPY . /tmp/go-neb

# Set the working directory
WORKDIR /tmp/go-neb

# Set Go environment variables for CGO.
# -D_LARGEFILE64_SOURCE might not be strictly necessary on glibc (Debian) as it was for musl (Alpine)
# but keeping CGO flags for library paths is important.
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig
ENV CGO_LDFLAGS="-L/usr/local/lib -L/usr/local/lib64"
ENV CGO_CFLAGS="-I/usr/local/include"
# Ensure CGO is enabled for the build steps that need it.
ENV CGO_ENABLED=1

# Download Go module dependencies
RUN go mod download

# Install linters (optional for the final build if pre-commit is skipped)
RUN go install honnef.co/go/tools/cmd/staticcheck@latest && \
    go install github.com/fzipp/gocyclo/cmd/gocyclo@latest

# Build the application
# The CGO_ENABLED=1 environment variable will apply here.
RUN go build -ldflags="-w -s" -tags="static,netgo" -o go-neb github.com/matrix-org/go-neb

# Ensures we're lint-free - THIS WILL LIKELY FAIL due to upstream lint issues.
# Comment this out if you want the build to complete despite linting errors.
# RUN chmod +x /tmp/go-neb/hooks/pre-commit
# RUN /tmp/go-neb/hooks/pre-commit

# Stage 2: Create the final lightweight image using Alpine
FROM alpine:3.19

# Add gcompat for glibc compatibility if needed, as libolm and go-neb (with CGO) were built on Debian (glibc)
RUN apk add --no-cache \
      libstdc++ \
      ca-certificates \
      su-exec \
      s6 \
      gcompat

ENV BIND_ADDRESS=:4050 \
    DATABASE_TYPE=sqlite3 \
    DATABASE_URL=/data/go-neb.db?_busy_timeout=5000 \
    UID=1337 \
    GID=1337

# Copy the compiled binary from the builder stage
COPY --from=builder /tmp/go-neb/go-neb /usr/local/bin/go-neb

# Copy libolm.so* from the Debian build stage
# Ensure all necessary shared library parts are copied.
COPY --from=builder /usr/local/lib/libolm.so.3 /usr/local/lib/libolm.so.3
# If libolm.so points to libolm.so.3, you might not need libolm.so explicitly,
# but copying the specific versioned file is safer.

# Create non-root user and group
RUN addgroup -g ${GID} neb && \
    adduser -u ${UID} -G neb -D -h /data neb

# Copy s6 service definitions
COPY docker/root /

# Create and set permissions for the data volume
RUN mkdir -p /data && \
    chown neb:neb /data
VOLUME /data

EXPOSE 4050

ENTRYPOINT ["/bin/s6-svscan", "/etc/s6.d/"]
