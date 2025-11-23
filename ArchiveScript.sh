project_path=$(cd `dirname $0`; pwd)

project_name="RuntimeViewer"

scheme_name="RuntimeViewerUsingAppKit"

development_mode="Release"

build_path=${project_path}/build

exportOptionsPlistPath=${project_path}/ArchiveExportConfig.plist

exportAppPath=${project_path}/Archives


echo '///-----------'
echo '/// 正在编译工程:'${development_mode}
echo '///-----------'
xcodebuild \
archive \
-scheme ${scheme_name} \
-configuration ${development_mode} \
-destination 'generic/platform=macOS' \
-archivePath ${build_path}/${project_name}.xcarchive \
ARCHS="x86_64 arm64e" || exit

echo '///--------'
echo '/// 编译完成'
echo '///--------'
echo ''

echo '///----------'
echo '/// 开始打包App'
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
echo '/// App已导出'
echo '///----------'
open $exportFullPath
else
echo '///-------------'
echo '/// App导出失败 '
echo '///-------------'
fi
echo '///------------'
echo '/// App打包完成  '
echo '///-----------='
echo ''

exit 0


