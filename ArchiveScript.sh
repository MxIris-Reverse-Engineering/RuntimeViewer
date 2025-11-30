project_path=$(cd `dirname $0`; pwd)

project_name="RuntimeViewer"

scheme_name="RuntimeViewerUsingAppKit"

development_mode="Release"

build_path=${project_path}/build

exportOptionsPlistPath=${project_path}/ArchiveExportConfig.plist

exportAppPath=${project_path}/Archives


echo '///-----------'
echo '/// Building RuntimeViewerCatalystHelper: '${development_mode}
echo '///-----------'
xcodebuild \
build \
-scheme 'RuntimeViewerCatalystHelper' \
-configuration ${development_mode} \
-destination 'generic/platform=macOS,variant=Mac Catalyst' || exit

echo '///-----------'
echo '/// Building '${scheme_name}': '${development_mode}
echo '///-----------'
xcodebuild \
archive \
-scheme ${scheme_name} \
-configuration ${development_mode} \
-destination 'generic/platform=macOS' \
-archivePath ${build_path}/${project_name}.xcarchive || exit

echo '///--------'
echo '/// Build finished'
echo '///--------'
echo ''

echo '///----------'
echo '/// Starting App Export'
echo '///----------'

exportFolderName="${project_name}_$(date +"%Y-%m-%d_%H-%M-%S")"
exportFullPath="${exportAppPath}/${exportFolderName}"
mkdir -p "$exportFullPath"

xcodebuild -exportArchive -archivePath ${build_path}/${project_name}.xcarchive \
-configuration ${development_mode} \
-exportPath ${exportFullPath} \
-exportOptionsPlist ${exportOptionsPlistPath} \
-quiet || exit

if [ -e $exportFullPath/$project_name.app ]; then
echo '///----------'
echo '/// App Exported'
echo '///----------'
open $exportFullPath
else
echo '///-------------'
echo '/// App Export Failed '
echo '///-------------'
fi
echo '///------------'
echo '/// App Export Complete  '
echo '///-----------='
echo ''

exit 0


