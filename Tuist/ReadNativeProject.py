#!/usr/bin/env python3
"""Prints an Xcode project as the JSON `plutil -convert json` makes of a project.pbxproj.

Usage: python3 -I Tuist/ReadNativeProject.py <path to an .xcodeproj>

TuistScript.sh reads the native projects in two places — `check` compares their targets and
configurations with the Tuist project's, and `generate` lays the Tuist project's navigator out like the
native one — and both were written against the object table of a project.pbxproj. A project that keeps
a project.pbxproj is handed to plutil unchanged. A project saved in Xcode 27's project.xcproj format
(JSON with trailing commas, references by navigator path, `KEY[config=Name]` settings) is converted into
the same shape, covering what those two readers use: the project, its targets, their configuration lists
and configurations with base xcconfig files and build settings, and the navigator's groups, files and
synchronized folders. Everything else in the project (build phases, dependencies, packages, membership
exceptions) is left out.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

CONFIGURATION_CONDITION = re.compile(r"\[config=([^\]]+)\]")
FILE_TYPES_BY_EXTENSION = {
    ".entitlements": "text.plist.entitlements",
    ".h": "sourcecode.c.h",
    ".icon": "folder.iconcomposer.icon",
    ".json": "text.json",
    ".m": "sourcecode.c.objc",
    ".md": "net.daringfireball.markdown",
    ".plist": "text.plist.xml",
    ".sh": "text.script.sh",
    ".swift": "sourcecode.swift",
    ".xcconfig": "text.xcconfig",
    ".xcodeproj": "wrapper.pb-project",
    ".xcstrings": "text.json.xcstrings",
    ".xctestplan": "text",
}


class ProjectFormatError(Exception):
    pass


def without_trailing_commas(text):
    """Drops every comma that closes an array or an object, which project.xcproj writes and JSON forbids."""
    characters = []
    index = 0
    inside_string = False
    while index < len(text):
        character = text[index]
        if inside_string:
            characters.append(character)
            if character == "\\":
                characters.append(text[index + 1])
                index += 2
                continue
            if character == '"':
                inside_string = False
        elif character == '"':
            inside_string = True
            characters.append(character)
        elif character == ",":
            next_index = index + 1
            while next_index < len(text) and text[next_index] in " \t\r\n":
                next_index += 1
            if next_index >= len(text) or text[next_index] not in "]}":
                characters.append(character)
        else:
            characters.append(character)
        index += 1
    return "".join(characters)


def settings_for_configuration(build_settings, configuration_name):
    """The settings one configuration sees: unconditional keys, plus `KEY[config=Name]` keys of this
    configuration with that condition removed. Other conditions stay in the key, as a project.pbxproj
    writes them."""
    unconditional = {}
    specific = {}
    for key, value in (build_settings or {}).items():
        conditions = CONFIGURATION_CONDITION.findall(key)
        if not conditions:
            unconditional[key] = value
        elif conditions == [configuration_name]:
            specific[CONFIGURATION_CONDITION.sub("", key)] = value
    return {**unconditional, **specific}


class ProjectConverter:
    def __init__(self, document, project_directory):
        self.document = document
        self.project_directory = project_directory
        self.objects = {}
        self.identifiers_by_navigator_path = {}
        self.identifiers_by_declared_identifier = {}

    def identifier(self, seed):
        return hashlib.sha256(f"ReadNativeProject:{seed}".encode()).hexdigest()[:24].upper()

    def add_element(self, entry, parent_navigator_path):
        kind = entry.get("kind", "file")
        raw_path = entry.get("path")
        name = entry.get("name")
        source_tree = "<group>"
        path = raw_path
        if raw_path is not None:
            if raw_path.startswith("<PROJECT>/"):
                source_tree, path = "SOURCE_ROOT", raw_path[len("<PROJECT>/"):]
            elif raw_path.startswith("<PRODUCTS>/"):
                source_tree, path = "BUILT_PRODUCTS_DIR", raw_path[len("<PRODUCTS>/"):]
            elif raw_path.startswith("/"):
                source_tree = "<absolute>"
            elif raw_path.startswith("<"):
                raise ProjectFormatError(f"unknown path base in {raw_path}")
        label = name or os.path.basename(path or "")
        navigator_path = f"{parent_navigator_path}/{label}" if parent_navigator_path else label
        identifier = entry.get("id") or self.identifier(f"{kind}:{navigator_path}")
        if identifier in self.objects:
            identifier = self.identifier(f"{kind}:{navigator_path}:{len(self.objects)}")

        if kind == "group":
            item = {"isa": "PBXGroup"}
        elif kind == "variant-group":
            item = {"isa": "PBXVariantGroup"}
        elif kind == "folder":
            item = {"isa": "PBXFileSystemSynchronizedRootGroup"}
            if "file-types" in entry:
                item["explicitFileTypes"] = entry["file-types"]
        elif kind == "file":
            item = {"isa": "PBXFileReference"}
            file_type = entry.get("type") or FILE_TYPES_BY_EXTENSION.get(os.path.splitext(path or "")[1])
            # A local package is a plain path in project.xcproj and a `wrapper` file in a project.pbxproj.
            if not file_type and source_tree == "SOURCE_ROOT" and os.path.isfile(os.path.join(self.project_directory, path, "Package.swift")):
                file_type = "wrapper"
            if file_type:
                item["explicitFileType" if source_tree == "BUILT_PRODUCTS_DIR" else "lastKnownFileType"] = file_type
            if entry.get("index") is False:
                item["includeInIndex"] = "0"
        else:
            raise ProjectFormatError(f"unknown navigator item kind {kind!r} at {navigator_path}")
        item["sourceTree"] = source_tree
        if path:
            item["path"] = path
        if name:
            item["name"] = name
        elif path and "/" in path and source_tree != "BUILT_PRODUCTS_DIR":
            item["name"] = os.path.basename(path)
        if kind in ("group", "variant-group"):
            item["children"] = [self.add_element(child, navigator_path) for child in entry.get("children", [])]

        self.objects[identifier] = item
        self.identifiers_by_navigator_path.setdefault(navigator_path, identifier)
        if "id" in entry:
            self.identifiers_by_declared_identifier[entry["id"]] = identifier
        return identifier

    def resolve(self, reference):
        if reference.startswith("id:"):
            identifier = self.identifiers_by_declared_identifier.get(reference[len("id:"):])
        else:
            identifier = self.identifiers_by_navigator_path.get(reference)
        if identifier is None:
            raise ProjectFormatError(f"nothing in the navigator at {reference!r}")
        return identifier

    def configuration_list(self, owner, configuration_names, files_by_configuration, build_settings):
        configuration_identifiers = []
        for configuration_name in configuration_names:
            configuration = {
                "isa": "XCBuildConfiguration",
                "name": configuration_name,
                "buildSettings": settings_for_configuration(build_settings, configuration_name),
            }
            base_file = files_by_configuration.get(configuration_name)
            if isinstance(base_file, str):
                configuration["baseConfigurationReference"] = self.resolve(base_file)
            elif isinstance(base_file, dict):
                configuration["baseConfigurationReferenceAnchor"] = self.resolve(base_file["anchor"])
                configuration["baseConfigurationReferenceRelativePath"] = base_file["relative-path"]
            elif base_file is not None:
                raise ProjectFormatError(f"unexpected base configuration {base_file!r} for {owner}")
            identifier = self.identifier(f"configuration:{owner}:{configuration_name}")
            self.objects[identifier] = configuration
            configuration_identifiers.append(identifier)
        list_identifier = self.identifier(f"configuration-list:{owner}")
        self.objects[list_identifier] = {
            "isa": "XCConfigurationList",
            "buildConfigurations": configuration_identifiers,
            "defaultConfigurationName": self.document.get("default-configuration", configuration_names[-1]),
        }
        return list_identifier

    def convert(self):
        main_group_identifier = self.identifier("main-group")
        main_group = {"isa": "PBXGroup", "sourceTree": "<group>"}
        main_group["children"] = [self.add_element(entry, "") for entry in self.document.get("files", [])]
        self.objects[main_group_identifier] = main_group

        configuration_names = [configuration["name"] for configuration in self.document["configurations"]]
        project_list = self.configuration_list(
            "project",
            configuration_names,
            {configuration["name"]: configuration.get("file") for configuration in self.document["configurations"]},
            self.document.get("build-settings"),
        )

        target_identifiers = []
        product_identifiers = set()
        for target in self.document.get("targets", []):
            target_name = target["name"]
            item = {
                "isa": "PBXAggregateTarget" if target.get("kind") == "aggregate" else "PBXNativeTarget",
                "name": target_name,
                "buildConfigurationList": self.configuration_list(
                    f"target:{target_name}",
                    configuration_names,
                    {configuration["name"]: configuration.get("file") for configuration in target.get("specialized-configurations", [])},
                    target.get("build-settings"),
                ),
            }
            if "product" in target:
                item["productReference"] = self.resolve(target["product"])
                product_identifiers.add(item["productReference"])
            identifier = target.get("id") or self.identifier(f"target:{target_name}")
            self.objects[identifier] = item
            target_identifiers.append(identifier)

        project = {
            "isa": "PBXProject",
            "buildConfigurationList": project_list,
            "mainGroup": main_group_identifier,
            "targets": target_identifiers,
        }
        product_groups = [identifier for identifier, item in self.objects.items()
                          if item["isa"] == "PBXGroup" and product_identifiers & set(item.get("children", []))]
        if len(product_groups) == 1:
            project["productRefGroup"] = product_groups[0]
        root_identifier = self.identifier("project")
        self.objects[root_identifier] = project
        return {"archiveVersion": "1", "objectVersion": "77", "objects": self.objects, "rootObject": root_identifier}


def read_project(project_path):
    property_list = os.path.join(project_path, "project.pbxproj")
    if os.path.exists(property_list):
        return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", property_list]))
    project_file = os.path.join(project_path, "project.xcproj")
    if not os.path.exists(project_file):
        raise ProjectFormatError(f"{project_path} has neither project.pbxproj nor project.xcproj")
    with open(project_file, encoding="utf-8") as handle:
        document = json.loads(without_trailing_commas(handle.read()))
    return ProjectConverter(document, os.path.dirname(os.path.abspath(project_path))).convert()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ReadNativeProject.py <path to an .xcodeproj>")
    try:
        json.dump(read_project(sys.argv[1]), sys.stdout)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, ProjectFormatError) as error:
        sys.exit(f"ReadNativeProject.py: {sys.argv[1]}: {type(error).__name__}: {error}")
