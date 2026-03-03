#!/bin/bash

set -e
set -o pipefail

project_path=$(cd "$(dirname "$0")"; pwd)
project_name="RuntimeViewer"
workspace="${project_path}/${project_name}.xcworkspace"
scheme_name="RuntimeViewer iOS"
configuration="Release"
cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)

derived_data_path="${project_path}/DerivedData"
build_products_path="${derived_data_path}/Build/Products/${configuration}-iphonesimulator"
export_path="${project_path}/Products/Archives/Products/Export"
output_zip="${export_path}/${project_name}-iOS-Simulator.zip"

echo '///-----------'
echo '/// Building iOS Simulator App'
echo '/// Scheme: '"${scheme_name}"
echo '/// Configuration: '"${configuration}"
echo '/// Parallel compile tasks: '"${cpu_cores}"
echo '///-----------'
echo ''

xcodebuild build \
    -workspace "${workspace}" \
    -scheme "${scheme_name}" \
    -configuration "${configuration}" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${derived_data_path}" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -jobs "${cpu_cores}" \
    CODE_SIGNING_ALLOWED=NO | xcbeautify || exit

app_path="${build_products_path}/${project_name}.app"

if [ ! -d "${app_path}" ]; then
    echo "Error: App not found at ${app_path}"
    exit 1
fi

echo ''
echo '///-----------'
echo '/// Packaging iOS Simulator App'
echo '///-----------'

mkdir -p "${export_path}"
rm -f "${output_zip}"
/usr/bin/ditto -c -k --keepParent "${app_path}" "${output_zip}"

echo ''
echo '///------------'
echo '/// All Done! Output: '"${output_zip}"
echo '///-----------='

open -R "${output_zip}"

exit 0
