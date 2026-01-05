project_path=$(cd `dirname $0`; pwd)

project_name="RuntimeViewer"

scheme_name="RuntimeViewer macOS"

development_mode="Release"

build_path=${project_path}/build

exportOptionsPlistPath=${project_path}/ArchiveExportConfig.plist

exportAppPath=${project_path}/Archives


echo '///-----------'
echo '/// Building RuntimeViewer CatalystHelper: '${development_mode}
echo '///-----------'

xcodebuild \
build \
-workspace ${project_path}/${project_name}.xcworkspace \
-scheme 'RuntimeViewer CatalystHelper' \
-configuration ${development_mode} \
-destination 'generic/platform=macOS,variant=Mac Catalyst' || exit

echo '///-----------'
echo '/// Archiving '${scheme_name}': '${development_mode}
echo '///-----------'

xcodebuild \
archive \
-workspace ${project_path}/${project_name}.xcworkspace \
-scheme ${scheme_name} \
-configuration ${development_mode} \
-destination 'generic/platform=macOS' \
-archivePath ${build_path}/${project_name}.xcarchive || exit

open ${build_path}/${project_name}.xcarchive

echo '///------------'
echo '/// App Archive Complete  '
echo '///-----------='
echo ''

exit 0


