#!/bin/bash

set -e
set -o pipefail


project_path=$(cd `dirname $0`; pwd)
project_name="RuntimeViewer"
scheme_name="RuntimeViewer macOS"
development_mode="Release"


build_path=${project_path}/Products/Archives
final_export_path=${build_path}/Products/Export
export_options_plist_path=${project_path}/ArchiveExportConfig.plist

catalyst_export_options_plist_path=${project_path}/ArchiveExportConfig-Catalyst.plist
catalyst_helper_export_path=${project_path}/RuntimeViewerUsingAppKit
catalyst_helper_app_path=${catalyst_helper_export_path}/RuntimeViewerCatalystHelper.app
catalyst_helper_archive_path=${build_path}/RuntimeViewerCatalystHelper.xcarchive

notary_profile_name="notarytool-password" 

echo '///-----------'
echo '/// Archiving RuntimeViewerCatalystHelper: '${development_mode}
echo '///-----------'

xcodebuild \
archive \
-workspace ${project_path}/${project_name}.xcworkspace \
-scheme 'RuntimeViewerCatalystHelper' \
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
-exportOptionsPlist ${catalyst_export_options_plist_path} \
-quiet || exit

rm -f "${catalyst_helper_export_path}/Packaging.log"
rm -f "${catalyst_helper_export_path}/DistributionSummary.plist"
rm -f "${catalyst_helper_export_path}/ExportOptions.plist"

echo '///------------'
echo '/// RuntimeViewerCatalystHelper Archive Complete  '
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
-archivePath ${build_path}/${project_name}.xcarchive \
| xcbeautify || exit

echo '///------------'
echo '/// '${scheme_name}' Archive Complete'
echo '///-----------='
echo ''

echo '///-----------'
echo '/// Exporting '${scheme_name}
echo '///-----------'

if [ -d "${final_export_path}" ]; then
    rm -rf "${final_export_path}"
fi

xcodebuild \
-exportArchive \
-archivePath "${build_path}/${project_name}.xcarchive" \
-configuration ${development_mode} \
-exportPath "${final_export_path}" \
-exportOptionsPlist "${export_options_plist_path}" \
-quiet || exit

app_path="${final_export_path}/${project_name}.app"
zip_path="${final_export_path}/${project_name}.zip"

if [ ! -d "$app_path" ]; then
    echo "Error: App not found at $app_path"
    exit 1
fi

echo '///------------'
echo '/// Export Complete: '${app_path}
echo '///-----------='
echo ''

if [ -z "$notary_profile_name" ]; then
    echo "Warning: notary_profile_name is empty. Skipping notarization."
    open "${final_export_path}"
    exit 0
fi

echo '///-----------'
echo '/// Notarizing...'
echo '///-----------'

echo "Zipping app for notarization..."
/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

echo "Submitting to Apple Notary Service (This may take a few minutes)..."

xcrun notarytool submit "$zip_path" \
--keychain-profile "$notary_profile_name" \
--wait || exit

echo '///------------'
echo '/// Notarization Accepted. Stapling Ticket...'
echo '///-----------='

xcrun stapler staple "$app_path"

echo "Stapling Complete."

spctl --assess --verbose "$app_path"

echo '///------------'
echo '/// All Done! Opening Output Folder.'
echo '///-----------='

open "${final_export_path}"

exit 0