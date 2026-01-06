#!/bin/bash

set -e
set -o pipefail

project_path=$(cd `dirname $0`; pwd)

project_name="RuntimeViewer"

scheme_name="RuntimeViewer macOS"

development_mode="Release"

build_path=${project_path}/archive

export_options_plist_path=${project_path}/ArchiveExportConfig.plist

catalyst_helper_export_path=${project_path}/RuntimeViewerUsingAppKit

catalyst_helper_app_path=${catalyst_helper_export_path}/RuntimeViewerCatalystHelper.app

catalyst_helper_archive_path=${build_path}/RuntimeViewerCatalystHelper.xcarchive

echo '///-----------'
echo '/// Archiving RuntimeViewer CatalystHelper: '${development_mode}
echo '///-----------'

xcodebuild \
archive \
-workspace ${project_path}/${project_name}.xcworkspace \
-scheme 'RuntimeViewer CatalystHelper' \
-configuration ${development_mode} \
-destination 'generic/platform=macOS,variant=Mac Catalyst' \
-archivePath ${catalyst_helper_archive_path} | xcbeautify || exit

if [ -d "${catalyst_helper_app_path}" ]; then
    rm -rf "${catalyst_helper_app_path}"
fi

xcodebuild \
-exportArchive -archivePath ${catalyst_helper_archive_path} \
-configuration ${development_mode} \
-exportPath ${catalyst_helper_export_path} \
-exportOptionsPlist ${export_options_plist_path} \
-quiet | xcbeautify || exit

echo '///------------'
echo '/// RuntimeViewer CatalystHelper Archive Complete  '
echo '///-----------='
echo ''


echo '///-----------'
echo '/// Archiving '${scheme_name}': '${development_mode}
echo '///-----------'

xcodebuild \
archive \
-workspace ${project_path}/${project_name}.xcworkspace \
-scheme "${scheme_name}" \
-configuration ${development_mode} \
-destination 'generic/platform=macOS' \
-archivePath ${build_path}/${project_name}.xcarchive || exit

open ${build_path}/${project_name}.xcarchive

echo '///------------'
echo '/// RuntimeViewer macOS Archive Complete  '
echo '///-----------='
echo ''

exit 0
