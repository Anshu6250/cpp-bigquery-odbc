#!/bin/bash
#
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

source "$(dirname "$0")/../../lib/init.sh"
source module ci/install-dependencies.sh

source module ci/cloudbuild/builds/lib/cmake.sh
source module ci/cloudbuild/builds/lib/bazel.sh
source module ci/cloudbuild/builds/lib/secrets.sh
source module ci/cloudbuild/builds/lib/unit-tests.sh
source module ci/lib/io.sh

WORKSPACE_DIR=$(pwd)

# Export as env variable
VCPKG_VERSION=$(cat /tmp/vcpkg-version.txt)
export VCPKG_VERSION
echo "Using VCPKG_VERSION=$VCPKG_VERSION"

# Vcpkg install and configure
export VCPKG_ROOT=/vcpkg
git clone --branch "$VCPKG_VERSION" https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
cd "$VCPKG_ROOT"
git checkout "$VCPKG_VERSION"

# Bootstrap
./bootstrap-vcpkg.sh -disableMetrics

cd "$WORKSPACE_DIR"
# Run unit tests
mapfile -t args < <(bazel::common_args)
mapfile -t unit_tests_args < <(unit_tests::bazel_args)
mapfile -t secrets_bazel < <(secrets::bazel_args)

io::run bazel test "${args[@]}" "${secrets_bazel[@]}" "${unit_tests_args[@]}" --test_tag_filters=unit-tests ...

# Run the integration tests
mapfile -t cmake_args < <(cmake::common_args)

BUILD_DIR="/opt/odbc-driver"
# This is the name of DSN set in odbc.ini
export ODBC_TESTS_DSN="SampleDSNGoogleDriver"
export CPP_BIGQUERY_ODBC_TEST_TABLE_PREFIX=${TRIGGER_NAME//[-:;.,?]/_}_${BRANCH_NAME//[-:;.,?]/_}

# Check if unixODBC is installed
if command -v odbcinst &>/dev/null; then
  export UNIXODBC_INSTALLED=true
  echo "unixODBC is installed."
else
  export UNIXODBC_INSTALLED=false
  export ODBCINSTINI=/opt/odbc-driver/odbcinst.ini
  echo "unixODBC is not installed."
fi

io::run cmake -B "$BUILD_DIR" \
  "${cmake_args[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
  -DCMAKE_CXX_STANDARD=17 \
  -DODBC_INTEGRATION_TESTING=ON \
  -DBQ_DRIVER_INTEGRATION_TESTS=ON \
  -DODBC_DEMO_TESTING=ON \
  -DODBC_EXAMPLES=ON \
  -DODBC_UNIT_TESTING=OFF \
  -DCLIENT_LIBRARY_INTEGRATION_TESTING=OFF
io::run cmake --build cmake-out

# Copy the roots.pem file to the .so directory to run test cases.
cp /opt/odbc-driver/roots.pem "cmake-out/google/cloud/odbc/roots.pem"

# Start idle connect proxy for Storage API keepalive integration tests
PROXY_PORT=8888
PROXY_PID=""
PROXY_LOG="/tmp/idle_connect_proxy.log"

cleanup_proxy() {
  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo "Terminating idle connect proxy..."
    kill "${PROXY_PID}" 2>/dev/null || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi
  if [[ -f "${PROXY_LOG}" ]]; then
    echo "=== Idle Connect Proxy Log Output ==="
    cat "${PROXY_LOG}" || true
    echo "=== End Idle Connect Proxy Log Output ==="
  fi
}
trap cleanup_proxy EXIT

if [[ -f "${WORKSPACE_DIR}/tools/idle_connect_proxy/idle_connect_proxy.py" ]]; then
  echo "Starting idle connect proxy on port ${PROXY_PORT}..."
  python3 "${WORKSPACE_DIR}/tools/idle_connect_proxy/idle_connect_proxy.py" \
    --port "${PROXY_PORT}" \
    --idle-timeout 40 \
    --mode reset \
    > "${PROXY_LOG}" 2>&1 &
  PROXY_PID=$!
  export BQ_ODBC_IDLE_PROXY="127.0.0.1:${PROXY_PORT}"
  export BQ_ODBC_IDLE_PROXY_PAUSE_SECONDS="45"
  export BQ_ODBC_IDLE_PROXY_EXPECT="success"
  echo "Idle connect proxy started with PID ${PROXY_PID} on 127.0.0.1:${PROXY_PORT}"
fi

mapfile -t ctest_args < <(ctest::common_args)
echo "Running IdleProxy integration tests..."
io::run env -C cmake-out ctest "${ctest_args[@]}" -R "IdleProxy"
