project_path=$(cd `dirname $0`; pwd)

project_name="RuntimeViewer"

scheme_name="RuntimeViewerUsingAppKit"

development_mode="Debug"

build_path=${project_path}/build

xcodebuild build -scheme ${scheme_name} -configuration ${development_mode} -destination 'generic/platform=macOS' ARCHS="x86_64 arm64e"

exit 0


