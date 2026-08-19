#!/usr/bin/env python3

"""Validate that the SwiftPM and Tuist manifests describe equivalent packages."""

from __future__ import annotations

import dataclasses
import json as javascript_object_notation
import os as operating_system
import pathlib
import subprocess
import sys as system
from typing import Any


PACKAGE_DIRECTORIES = (
    "RuntimeViewerCore",
    "RuntimeViewerPackages",
    "RuntimeViewerMCP",
)


@dataclasses.dataclass(frozen=True)
class DependencyRequirement:
    kind: str
    exact_version: str | None = None
    lower_bound: str | None = None
    upper_bound: str | None = None
    reference: str | None = None

    def __str__(self) -> str:
        if self.kind == "exact":
            return f"exact {self.exact_version}"
        if self.kind == "range":
            return f"range [{self.lower_bound}, {self.upper_bound})"
        return f"{self.kind} {self.reference}"


@dataclasses.dataclass(frozen=True)
class ExternalDependency:
    identity: str
    repository_location: str
    requirement: DependencyRequirement
    traits: frozenset[str]


@dataclasses.dataclass(frozen=True)
class TopologyExceptions:
    tuist_only_targets: frozenset[str] = frozenset()
    tuist_only_internal_dependencies: tuple[tuple[str, frozenset[str]], ...] = ()

    def allowed_internal_dependencies(self, target_name: str) -> frozenset[str]:
        return dict(self.tuist_only_internal_dependencies).get(target_name, frozenset())


TOPOLOGY_EXCEPTIONS_BY_PACKAGE = {
    "RuntimeViewerPackages": TopologyExceptions(
        tuist_only_targets=frozenset({"UXKit", "UXKitCoordinator"}),
        tuist_only_internal_dependencies=(
            ("RuntimeViewerArchitectures", frozenset({"UXKitCoordinator"})),
            ("RuntimeViewerUI", frozenset({"UXKit"})),
        ),
    ),
}


# RuntimeViewerCore receives swift-demangling transitively through the reverse-
# engineering packages. Declaring it at the Tuist root is intentional: it gives
# local-dependency mode a root identity that can be replaced by a path package.
ADDITIONAL_TUIST_DEPENDENCIES = {
    "swift-demangling": ExternalDependency(
        identity="swift-demangling",
        repository_location="https://github.com/MxIris-Reverse-Engineering/swift-demangling",
        requirement=DependencyRequirement(
            kind="range",
            lower_bound="0.4.5",
            upper_bound="1.0.0",
        ),
        traits=frozenset({"default"}),
    ),
}


class ManifestValidationFailure(Exception):
    """Raised when a manifest or command cannot be interpreted safely."""


def run_json_command(
    command: list[str],
    repository_root: pathlib.Path,
) -> dict[str, Any]:
    sanitized_environment = operating_system.environ.copy()
    sanitized_environment.pop("USING_LOCAL_DEPENDENCIES", None)
    sanitized_environment.pop("TUIST_USING_LOCAL_DEPENDENCIES", None)

    completed_process = subprocess.run(
        command,
        cwd=repository_root,
        env=sanitized_environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed_process.returncode != 0:
        diagnostic = completed_process.stderr.strip() or completed_process.stdout.strip()
        raise ManifestValidationFailure(
            f"Command failed ({completed_process.returncode}): {' '.join(command)}\n{diagnostic}"
        )

    try:
        decoded_value = javascript_object_notation.loads(completed_process.stdout)
    except javascript_object_notation.JSONDecodeError as error:
        raise ManifestValidationFailure(
            f"Command did not return valid JSON: {' '.join(command)}\n{error}"
        ) from error

    if not isinstance(decoded_value, dict):
        raise ManifestValidationFailure(
            f"Command returned a non-object JSON root: {' '.join(command)}"
        )
    return decoded_value


def load_swift_package_manifest(
    package_directory: str,
    repository_root: pathlib.Path,
) -> dict[str, Any]:
    return run_json_command(
        [
            "swift",
            "package",
            "dump-package",
            "--package-path",
            package_directory,
        ],
        repository_root,
    )


def load_tuist_project_manifest(
    package_directory: str,
    repository_root: pathlib.Path,
) -> dict[str, Any]:
    return run_json_command(
        ["tuist", "dump", "project", "--path", package_directory],
        repository_root,
    )


def require_dictionary(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestValidationFailure(f"Expected an object at {context}")
    return value


def require_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise ManifestValidationFailure(f"Expected an array at {context}")
    return value


def require_string(value: Any, context: str) -> str:
    if not isinstance(value, str):
        raise ManifestValidationFailure(f"Expected a string at {context}")
    return value


def manifest_targets(manifest: dict[str, Any], context: str) -> list[dict[str, Any]]:
    target_values = require_list(manifest.get("targets"), f"{context}.targets")
    return [
        require_dictionary(target_value, f"{context}.targets[{target_index}]")
        for target_index, target_value in enumerate(target_values)
    ]


def target_names(manifest: dict[str, Any], context: str) -> frozenset[str]:
    return frozenset(
        require_string(target.get("name"), f"{context}.targets.name")
        for target in manifest_targets(manifest, context)
    )


def swift_internal_dependencies(
    manifest: dict[str, Any],
    context: str,
) -> dict[str, frozenset[str]]:
    all_target_names = target_names(manifest, context)
    dependencies_by_target: dict[str, frozenset[str]] = {}

    for target in manifest_targets(manifest, context):
        target_name = require_string(target.get("name"), f"{context}.targets.name")
        dependency_names: set[str] = set()
        dependencies = require_list(
            target.get("dependencies", []),
            f"{context}.{target_name}.dependencies",
        )
        for dependency_index, dependency_value in enumerate(dependencies):
            dependency = require_dictionary(
                dependency_value,
                f"{context}.{target_name}.dependencies[{dependency_index}]",
            )
            for dependency_kind in ("target", "byName"):
                encoded_dependency = dependency.get(dependency_kind)
                if encoded_dependency is None:
                    continue
                encoded_values = require_list(
                    encoded_dependency,
                    f"{context}.{target_name}.{dependency_kind}",
                )
                if not encoded_values:
                    raise ManifestValidationFailure(
                        f"Empty {dependency_kind} dependency at {context}.{target_name}"
                    )
                dependency_name = require_string(
                    encoded_values[0],
                    f"{context}.{target_name}.{dependency_kind}.name",
                )
                if dependency_name in all_target_names:
                    dependency_names.add(dependency_name)
        dependencies_by_target[target_name] = frozenset(dependency_names)

    return dependencies_by_target


def tuist_internal_dependencies(
    manifest: dict[str, Any],
    context: str,
) -> dict[str, frozenset[str]]:
    all_target_names = target_names(manifest, context)
    dependencies_by_target: dict[str, frozenset[str]] = {}

    for target in manifest_targets(manifest, context):
        target_name = require_string(target.get("name"), f"{context}.targets.name")
        dependency_names: set[str] = set()
        dependencies = require_list(
            target.get("dependencies", []),
            f"{context}.{target_name}.dependencies",
        )
        for dependency_index, dependency_value in enumerate(dependencies):
            dependency = require_dictionary(
                dependency_value,
                f"{context}.{target_name}.dependencies[{dependency_index}]",
            )
            encoded_target = dependency.get("target")
            if encoded_target is None:
                continue
            target_dependency = require_dictionary(
                encoded_target,
                f"{context}.{target_name}.target",
            )
            dependency_name = require_string(
                target_dependency.get("name"),
                f"{context}.{target_name}.target.name",
            )
            if dependency_name in all_target_names:
                dependency_names.add(dependency_name)
        dependencies_by_target[target_name] = frozenset(dependency_names)

    return dependencies_by_target


def validate_target_topology(
    package_directory: str,
    swift_manifest: dict[str, Any],
    tuist_manifest: dict[str, Any],
) -> list[str]:
    validation_errors: list[str] = []
    exceptions = TOPOLOGY_EXCEPTIONS_BY_PACKAGE.get(
        package_directory,
        TopologyExceptions(),
    )
    swift_context = f"{package_directory}/Package.swift"
    tuist_context = f"{package_directory}/Project.swift"

    swift_names = target_names(swift_manifest, swift_context)
    tuist_names = target_names(tuist_manifest, tuist_context)

    missing_exception_targets = exceptions.tuist_only_targets - tuist_names
    if missing_exception_targets:
        validation_errors.append(
            f"{package_directory}: stale Tuist-only target exceptions: "
            f"{sorted(missing_exception_targets)}"
        )

    comparable_tuist_names = tuist_names - exceptions.tuist_only_targets
    if swift_names != comparable_tuist_names:
        validation_errors.append(
            f"{package_directory}: target sets differ; "
            f"SwiftPM-only={sorted(swift_names - comparable_tuist_names)}, "
            f"Tuist-only={sorted(comparable_tuist_names - swift_names)}"
        )

    swift_dependencies = swift_internal_dependencies(swift_manifest, swift_context)
    tuist_dependencies = tuist_internal_dependencies(tuist_manifest, tuist_context)
    for target_name in sorted(swift_names & comparable_tuist_names):
        allowed_dependencies = exceptions.allowed_internal_dependencies(target_name)
        actual_tuist_dependencies = tuist_dependencies[target_name]
        missing_exception_dependencies = allowed_dependencies - actual_tuist_dependencies
        if missing_exception_dependencies:
            validation_errors.append(
                f"{package_directory}.{target_name}: stale Tuist-only dependency exceptions: "
                f"{sorted(missing_exception_dependencies)}"
            )

        comparable_tuist_dependencies = actual_tuist_dependencies - allowed_dependencies
        expected_swift_dependencies = swift_dependencies[target_name]
        if expected_swift_dependencies != comparable_tuist_dependencies:
            validation_errors.append(
                f"{package_directory}.{target_name}: internal dependencies differ; "
                f"SwiftPM-only={sorted(expected_swift_dependencies - comparable_tuist_dependencies)}, "
                f"Tuist-only={sorted(comparable_tuist_dependencies - expected_swift_dependencies)}"
            )

    return validation_errors


def decode_requirement(
    encoded_requirement: Any,
    context: str,
) -> DependencyRequirement:
    requirement = require_dictionary(encoded_requirement, context)
    if "exact" in requirement:
        versions = require_list(requirement["exact"], f"{context}.exact")
        if len(versions) != 1:
            raise ManifestValidationFailure(f"Expected one exact version at {context}")
        return DependencyRequirement(
            kind="exact",
            exact_version=require_string(versions[0], f"{context}.exact[0]"),
        )

    if "range" in requirement:
        ranges = require_list(requirement["range"], f"{context}.range")
        if len(ranges) != 1:
            raise ManifestValidationFailure(f"Expected one version range at {context}")
        version_range = require_dictionary(ranges[0], f"{context}.range[0]")
        return DependencyRequirement(
            kind="range",
            lower_bound=require_string(
                version_range.get("lowerBound"),
                f"{context}.range.lowerBound",
            ),
            upper_bound=require_string(
                version_range.get("upperBound"),
                f"{context}.range.upperBound",
            ),
        )

    for reference_kind in ("branch", "revision"):
        if reference_kind not in requirement:
            continue
        references = require_list(
            requirement[reference_kind],
            f"{context}.{reference_kind}",
        )
        if len(references) != 1:
            raise ManifestValidationFailure(
                f"Expected one {reference_kind} reference at {context}"
            )
        return DependencyRequirement(
            kind=reference_kind,
            reference=require_string(
                references[0],
                f"{context}.{reference_kind}[0]",
            ),
        )

    raise ManifestValidationFailure(f"Unsupported dependency requirement at {context}")


def decode_external_dependencies(
    manifest: dict[str, Any],
    context: str,
) -> list[ExternalDependency]:
    encoded_dependencies = require_list(manifest.get("dependencies"), f"{context}.dependencies")
    external_dependencies: list[ExternalDependency] = []

    for dependency_index, dependency_value in enumerate(encoded_dependencies):
        dependency = require_dictionary(
            dependency_value,
            f"{context}.dependencies[{dependency_index}]",
        )
        encoded_source_control = dependency.get("sourceControl")
        if encoded_source_control is None:
            continue
        source_control_values = require_list(
            encoded_source_control,
            f"{context}.dependencies[{dependency_index}].sourceControl",
        )
        if len(source_control_values) != 1:
            raise ManifestValidationFailure(
                f"Expected one source-control value at {context}.dependencies[{dependency_index}]"
            )
        source_control = require_dictionary(
            source_control_values[0],
            f"{context}.dependencies[{dependency_index}].sourceControl[0]",
        )
        identity = require_string(
            source_control.get("identity"),
            f"{context}.dependencies[{dependency_index}].identity",
        )
        location = require_dictionary(
            source_control.get("location"),
            f"{context}.dependencies[{dependency_index}].location",
        )
        remote_values = require_list(
            location.get("remote"),
            f"{context}.dependencies[{dependency_index}].location.remote",
        )
        if len(remote_values) != 1:
            raise ManifestValidationFailure(
                f"Expected one remote location at {context}.dependencies[{dependency_index}]"
            )
        remote = require_dictionary(
            remote_values[0],
            f"{context}.dependencies[{dependency_index}].location.remote[0]",
        )
        repository_location = require_string(
            remote.get("urlString"),
            f"{context}.dependencies[{dependency_index}].location.remote.urlString",
        )
        encoded_traits = require_list(
            source_control.get("traits", []),
            f"{context}.dependencies[{dependency_index}].traits",
        )
        traits = frozenset(
            require_string(
                require_dictionary(
                    encoded_trait,
                    f"{context}.dependencies[{dependency_index}].traits[{trait_index}]",
                ).get("name"),
                f"{context}.dependencies[{dependency_index}].traits[{trait_index}].name",
            )
            for trait_index, encoded_trait in enumerate(encoded_traits)
        )
        external_dependencies.append(
            ExternalDependency(
                identity=identity,
                repository_location=repository_location,
                requirement=decode_requirement(
                    source_control.get("requirement"),
                    f"{context}.dependencies[{dependency_index}].requirement",
                ),
                traits=traits,
            )
        )

    return external_dependencies


def split_semantic_version(version: str) -> tuple[list[int], list[str] | None]:
    version_without_build_metadata = version.split("+", 1)[0]
    version_parts = version_without_build_metadata.split("-", 1)
    core_components: list[int] = []
    for component in version_parts[0].split("."):
        if not component.isdigit():
            raise ManifestValidationFailure(f"Unsupported semantic version: {version}")
        core_components.append(int(component))
    prerelease_components = version_parts[1].split(".") if len(version_parts) == 2 else None
    return core_components, prerelease_components


def compare_semantic_versions(first_version: str, second_version: str) -> int:
    first_core, first_prerelease = split_semantic_version(first_version)
    second_core, second_prerelease = split_semantic_version(second_version)
    component_count = max(len(first_core), len(second_core))
    first_core.extend([0] * (component_count - len(first_core)))
    second_core.extend([0] * (component_count - len(second_core)))
    if first_core != second_core:
        return -1 if first_core < second_core else 1

    if first_prerelease is None and second_prerelease is None:
        return 0
    if first_prerelease is None:
        return 1
    if second_prerelease is None:
        return -1

    for first_identifier, second_identifier in zip(first_prerelease, second_prerelease):
        if first_identifier == second_identifier:
            continue
        first_is_numeric = first_identifier.isdigit()
        second_is_numeric = second_identifier.isdigit()
        if first_is_numeric and second_is_numeric:
            return -1 if int(first_identifier) < int(second_identifier) else 1
        if first_is_numeric != second_is_numeric:
            return -1 if first_is_numeric else 1
        return -1 if first_identifier < second_identifier else 1

    if len(first_prerelease) == len(second_prerelease):
        return 0
    return -1 if len(first_prerelease) < len(second_prerelease) else 1


def range_contains(version: str, requirement: DependencyRequirement) -> bool:
    if requirement.kind != "range":
        raise ManifestValidationFailure(f"Expected a range requirement, got {requirement}")
    if requirement.lower_bound is None or requirement.upper_bound is None:
        raise ManifestValidationFailure(f"Incomplete range requirement: {requirement}")
    return (
        compare_semantic_versions(version, requirement.lower_bound) >= 0
        and compare_semantic_versions(version, requirement.upper_bound) < 0
    )


def intersect_requirements(
    identity: str,
    requirements: list[DependencyRequirement],
) -> DependencyRequirement:
    reference_requirements = [
        requirement
        for requirement in requirements
        if requirement.kind in {"branch", "revision"}
    ]
    if reference_requirements:
        if any(requirement != reference_requirements[0] for requirement in requirements):
            raise ManifestValidationFailure(
                f"{identity}: incompatible branch/revision requirements: "
                f"{[str(requirement) for requirement in requirements]}"
            )
        return reference_requirements[0]

    exact_versions = {
        requirement.exact_version
        for requirement in requirements
        if requirement.kind == "exact"
    }
    if len(exact_versions) > 1:
        raise ManifestValidationFailure(
            f"{identity}: incompatible exact requirements: {sorted(exact_versions)}"
        )
    if exact_versions:
        exact_version = next(iter(exact_versions))
        if exact_version is None:
            raise ManifestValidationFailure(f"{identity}: missing exact version")
        for requirement in requirements:
            if requirement.kind == "range" and not range_contains(exact_version, requirement):
                raise ManifestValidationFailure(
                    f"{identity}: {exact_version} is outside {requirement}"
                )
        return DependencyRequirement(kind="exact", exact_version=exact_version)

    range_requirements = [
        requirement for requirement in requirements if requirement.kind == "range"
    ]
    if len(range_requirements) != len(requirements):
        raise ManifestValidationFailure(
            f"{identity}: unsupported requirement combination: "
            f"{[str(requirement) for requirement in requirements]}"
        )

    lower_bound = range_requirements[0].lower_bound
    upper_bound = range_requirements[0].upper_bound
    if lower_bound is None or upper_bound is None:
        raise ManifestValidationFailure(f"{identity}: incomplete version range")
    for requirement in range_requirements[1:]:
        if requirement.lower_bound is None or requirement.upper_bound is None:
            raise ManifestValidationFailure(f"{identity}: incomplete version range")
        if compare_semantic_versions(requirement.lower_bound, lower_bound) > 0:
            lower_bound = requirement.lower_bound
        if compare_semantic_versions(requirement.upper_bound, upper_bound) < 0:
            upper_bound = requirement.upper_bound

    if compare_semantic_versions(lower_bound, upper_bound) >= 0:
        raise ManifestValidationFailure(
            f"{identity}: dependency ranges do not intersect: "
            f"{[str(requirement) for requirement in requirements]}"
        )
    return DependencyRequirement(
        kind="range",
        lower_bound=lower_bound,
        upper_bound=upper_bound,
    )


def expected_aggregate_dependencies(
    package_dependencies: list[ExternalDependency],
) -> dict[str, ExternalDependency]:
    declarations_by_identity: dict[str, list[ExternalDependency]] = {}
    for dependency in package_dependencies:
        declarations_by_identity.setdefault(dependency.identity, []).append(dependency)
    for additional_dependency in ADDITIONAL_TUIST_DEPENDENCIES.values():
        declarations_by_identity.setdefault(additional_dependency.identity, []).append(
            additional_dependency
        )

    expected_dependencies: dict[str, ExternalDependency] = {}
    for identity, declarations in declarations_by_identity.items():
        repository_locations = {
            declaration.repository_location for declaration in declarations
        }
        if len(repository_locations) != 1:
            raise ManifestValidationFailure(
                f"{identity}: package manifests use different repository locations: "
                f"{sorted(repository_locations)}"
            )
        expected_dependencies[identity] = ExternalDependency(
            identity=identity,
            repository_location=next(iter(repository_locations)),
            requirement=intersect_requirements(
                identity,
                [declaration.requirement for declaration in declarations],
            ),
            traits=frozenset().union(
                *(declaration.traits for declaration in declarations)
            ),
        )
    return expected_dependencies


def unique_dependencies_by_identity(
    dependencies: list[ExternalDependency],
    context: str,
) -> tuple[dict[str, ExternalDependency], list[str]]:
    dependencies_by_identity: dict[str, ExternalDependency] = {}
    duplicate_identities: set[str] = set()
    for dependency in dependencies:
        if dependency.identity in dependencies_by_identity:
            duplicate_identities.add(dependency.identity)
        dependencies_by_identity[dependency.identity] = dependency
    validation_errors = [
        f"{context}: duplicate dependency declaration for {identity}"
        for identity in sorted(duplicate_identities)
    ]
    return dependencies_by_identity, validation_errors


def validate_external_dependencies(
    package_dependencies: list[ExternalDependency],
    tuist_dependencies: list[ExternalDependency],
) -> list[str]:
    validation_errors: list[str] = []
    expected_dependencies = expected_aggregate_dependencies(package_dependencies)
    actual_dependencies, duplicate_errors = unique_dependencies_by_identity(
        tuist_dependencies,
        "Tuist/Package.swift",
    )
    validation_errors.extend(duplicate_errors)

    expected_identities = set(expected_dependencies)
    actual_identities = set(actual_dependencies)
    if expected_identities != actual_identities:
        validation_errors.append(
            "Tuist/Package.swift dependency identities differ; "
            f"missing={sorted(expected_identities - actual_identities)}, "
            f"unexpected={sorted(actual_identities - expected_identities)}"
        )

    for identity in sorted(expected_identities & actual_identities):
        expected_dependency = expected_dependencies[identity]
        actual_dependency = actual_dependencies[identity]
        if expected_dependency.repository_location != actual_dependency.repository_location:
            validation_errors.append(
                f"{identity}: repository location differs; "
                f"expected={expected_dependency.repository_location}, "
                f"actual={actual_dependency.repository_location}"
            )
        if expected_dependency.requirement != actual_dependency.requirement:
            validation_errors.append(
                f"{identity}: version requirement differs; "
                f"expected={expected_dependency.requirement}, "
                f"actual={actual_dependency.requirement}"
            )
        if expected_dependency.traits != actual_dependency.traits:
            validation_errors.append(
                f"{identity}: traits differ; "
                f"expected={sorted(expected_dependency.traits)}, "
                f"actual={sorted(actual_dependency.traits)}"
            )

    return validation_errors


def validate_manifests(repository_root: pathlib.Path) -> list[str]:
    validation_errors: list[str] = []
    package_dependencies: list[ExternalDependency] = []

    for package_directory in PACKAGE_DIRECTORIES:
        swift_manifest = load_swift_package_manifest(package_directory, repository_root)
        tuist_manifest = load_tuist_project_manifest(package_directory, repository_root)
        validation_errors.extend(
            validate_target_topology(
                package_directory,
                swift_manifest,
                tuist_manifest,
            )
        )
        package_dependencies.extend(
            decode_external_dependencies(
                swift_manifest,
                f"{package_directory}/Package.swift",
            )
        )

    tuist_package_manifest = load_swift_package_manifest("Tuist", repository_root)
    tuist_dependencies = decode_external_dependencies(
        tuist_package_manifest,
        "Tuist/Package.swift",
    )
    validation_errors.extend(
        validate_external_dependencies(package_dependencies, tuist_dependencies)
    )
    return validation_errors


def main() -> int:
    repository_root = pathlib.Path(__file__).resolve().parents[2]
    try:
        validation_errors = validate_manifests(repository_root)
    except ManifestValidationFailure as error:
        print(f"Manifest consistency validation could not run:\n{error}", file=system.stderr)
        return 1

    if validation_errors:
        print("Manifest consistency validation failed:", file=system.stderr)
        for validation_error in validation_errors:
            print(f"- {validation_error}", file=system.stderr)
        return 1

    print(
        "Manifest consistency validation passed for RuntimeViewerCore, "
        "RuntimeViewerPackages, and RuntimeViewerMCP."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
