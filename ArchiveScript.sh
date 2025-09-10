#工程绝对路径
project_path=$(cd `dirname $0`; pwd)

#工程名 将XXX替换成自己的工程名
project_name="RuntimeViewer"

#scheme名 将XXX替换成自己的sheme名
scheme_name="RuntimeViewerUsingAppKit"

#打包模式 Debug/Release
development_mode="Release"

#build文件夹路径
build_path=${project_path}/build

#plist文件所在路径
exportOptionsPlistPath=${project_path}/ArchiveExportConfig.plist

#导出App文件所在路径
exportAppPath=${project_path}/archive


echo '///-----------'
echo '/// 正在编译工程:'${development_mode}
echo '///-----------'
xcodebuild \
archive -workspace ${project_path}/${project_name}.xcworkspace \
-scheme ${scheme_name} \
-destination 'generic/platform=macOS' \
-configuration ${development_mode} \
-skipPackagePluginValidation -skipMacroValidation \
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


