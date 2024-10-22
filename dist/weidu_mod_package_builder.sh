#!/bin/bash

# Copyright (c) 2024 Argent77
# Version 2.1

# Supported parameters for script execution:
# type={archive_type}
# This parameter determines the resulting archive format.
# Supported archive types: iemod, windows, linux, macos, multi
# - iemod:        Creates a zip archive with the .iemod extension and no setup binary.
# - windows:      Creates a regular zip archive which includes a Windows setup binary.
# - linux:        Creates a regular zip archive which includes a Linux setup binary.
# - macos:        Creates a regular zip archive which includes a macOS setup binary and
#                 associated setup-*.command script file.
# - multi:        Creates a regular zip archive which includes setup binaries and scripts for all
#                 supported platforms:
#                 1) Size of the mod package will increase by about 10 MB compared to "iemod".
#                 2) On Windows platforms users will run setup-*.exe directly.
#                    For macOS and Linux interactive mod installation will be invoked by a script
#                    ("setup-*.command" for macOS, "setup-*.sh" for Linux), and the WeiDU binaries
#                    are placed into the "weidu_external/tools/weidu/{platform}" folder structure.
# Default archive type: iemod

# arch={architecture}
# This parameter determines the architecture of the included setup binary.
# It is currently only effective for Windows. Other platforms provide architecture-specific binaries
# only for WeiDU version 246.
# Supported architectures: amd64, x86, x86-legacy
# - x86-legacy: Specify this option to include a special WeiDU binary that is compatible with
#               older Windows versions and does not mangle non-ASCII characters in resource
#               filenames. This can be useful for specific mods, such as Generalized Biffing 
#               in conjunction with Infinity Animations.
# Default architecture: amd64

# suffix={type_or_string}
# Supported suffix types: version, none. Everything else is treated as a literal string.
# - none:    A symbolic name to indicate that no version suffix is added.
# - version: Uses the VERSION definition of the tp2 file of the mod.
# In all cases:
# - everything after the first whitespace character in the version string is ignored
# - illegal filename characters are replaced by underscores
# Default suffix: version

# extra={string}
# An arbitrary string that will be appended after the package base name but before the version suffix.
# Default: <empty string>

# naming: {type_or_string}
# This parameter defines the mod package base name.
# Supported naming types: tp2, ini. Everything else is treated as a literal string.
# - tp2: Uses the tp2 filename as base for generating the mod package base name.
# - ini: Fetches the "name" definition from the associated Project Infinity metadata ini file.
#        Falls back to "tp2" if not available.
# Default: tp2

# weidu: {type_or_number}
# WeiDU version to use for the setup binaries for platform-specific zip archives.
# Specify "latest" to use the latest WeiDU version, or a specific WeiDU version.
# Currently supported versions: 246 or later.
# Default: latest

# prefix_win, prefix_lin, prefix_mac: {string}
# Prefix string to use for platform-specific zip archive names.
# Default: win, lin, mac (for Windows, Linux and macOS platforms respectively)

# tp2_name: {string}
# This parameter defines the tp2 filename of the mod to include in the mod package.
# Specifying this option is only useful if a project contains multiple mods
# (e.g. EET, EET_end, EET_gui).
# Default: <empty string>

# multi_autoupdate: {boolean}
# This parameter is only considered if the "type" parameter is set to "multi".
# It defines whether the setup scripts for Linux and macOS should automatically update the
# WeiDU binary to the latest available version found in the game directory.
# Using the latest WeiDU version ensures max. compatibility with operations that result in
# temporary uninstallation or reinstallation of mod components.
# Windows setup is not affected by this parameter since it is automatically handled by WeiDU itself.
# Supported parameters: false, true, 0, 1
# Default: true

# case_sensitive: {boolean}
# This parameter specifies whether duplicate files which only differ in case should be preserved
# when found in the same folder of the mod.
# If this option is enabled then duplicate files may coexist in the same folder. This is only useful
# on Linux where filesystems are case-sensitive by default. Otherwise, duplicate files with the
# oldest modification date are removed.
# Supported parameters: false, true, 0, 1
# Default: false

#####################################
#     Start of script execution     #
#####################################

# Global variables:
# - archive_type:     Argument of the "type=" parameter (iemod, windows, linux, macos, multi)
# - arch:             Argument of the "arch=" parameter (amd64, x86, x86-legacy)
# - suffix:           Argument of the "suffix=" parameter (version, none, or <literal string>)
# - extra:            Argument of the "extra=" parameter
# - naming:           Argument of the "naming=" parameter (ini, tp2, or <literal string>)
# - weidu_version:    Argument of the "weidu=" parameter (latest, or a specific WeiDU version)
# - prefix_win        Argument of the "prefix_win=" parameter
# - prefix_lin        Argument of the "prefix_lin=" parameter
# - prefix_mac        Argument of the "prefix_mac=" parameter
# - mod_filter:       Argument of the "tp2_name=" parameter
# - multi_autoupdate: Argument of the "multi_autoupdate=" parameter
# - case_sensitive:   Argument of the "case_sensitive=" parameter
# - weidu_url_base:   Base URL for the JSON release definition.
# - weidu_min:        Supported minimum WeiDU version
# - bin_ext:          File extension of executable files (".exe" on Windows, empty string otherwise)
# - weidu_bin:        Filename of the WeiDU binary (irrelevant for archive types "iemod" and "multi")

# Prints a specified message to stderr.
printerr() {
  if [ $# -gt 0 ]; then
    printf "%s\n" "$*" >&2
  fi
}

# Including shell script libraries
DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
for name in "lib_base" "lib_params" "lib_paths" "lib_weidu"; do
  source "$DIR/${name}.sh"
  if [ $? -ne 0 ]; then printerr "ERROR: Unable to source script: ${name}.sh"; exit 1; fi
done

root="$PWD"

# Files to clean up after operation is completed
removables=()

# Paths to include in mod package if defined:
# - tp2_mod_path: path of mod folder
# - tp2_file:     path of separate tp2 file (old-style mods only)
# - ini_file:     path of separate ini file (old-style mods only; defined only if "tp2_file" is set)
# - setup_file:   path of setup binary
# - command_file: path of setup .command script (macOS only)

# Filenames for zip inclusion and exclusion lists
zip_include="zip_include.lst"
zip_exclude="zip_exclude.lst"

# Filename and full path of the mod package to create
archive_filename=""
archive_file_path=""

# Returns colon-delimited path strings:
# - relative base path for mod structure
# - tp2 file path
# - optional mod folder path (for old-style mods only).
# May contain more than one set of strings (e.g. if multiple tp2 files are found)
tp2_result=$(find_tp2)
if [ -z "$tp2_result" ]; then
  printerr "ERROR: No tp2 file found."
  exit 1
fi

# Loop through every potential mod
while [ -n "$tp2_result" ]; do
  # splitting tp2_result into variables: mod_root, tp2_file, tp2_mod_path
  split_to_vars "$tp2_result" "tp2_result" ":" "mod_root" "tp2_file" "tp2_mod_path"
  echo "Mod root: $mod_root"
  echo "Tp2 file: $tp2_file"
  if [ -n "$tp2_mod_path" ]; then
    echo "Tp2 mod folder: $tp2_mod_path"
  fi

  # Setting root folder for the mod file structure
  cd "$mod_root"

  # Setup binary filename
  setup_file=""
  # macOS setup .command filename
  command_file=""

  # Setting up setup binary file(s)
  if [ "$archive_type" = "multi" ]; then
    # Multi-platform setup
    if [ ! -d "weidu_external/tools/weidu" ]; then
      # Installing generic WeiDU binaries for Linux and macOS
      mkdir -pv weidu_external/tools/weidu/{osx,unix}
      removables+=("weidu_external")

      # Downloading WeiDU binaries
      weidu_bin="weidu"
      for folder in "osx" "unix"; do
        if [ "$folder" = "osx" ]; then
          os="macos"
        else
          os="linux"
        fi
        echo "Downloading WeiDU executable: $weidu_bin ($os, $arch)"
        download_weidu "$os" "$arch" "$weidu_version" "$weidu_bin" "weidu_external/tools/weidu/$folder"
        if [ $? -ne 0 ]; then
          clean_up "${removables[@]}"
          exit 1
        fi
        echo "weidu_external/tools/weidu/$folder/$weidu_bin" >>"$zip_include"
      done
    fi
    # Setting up setup scripts for Linux and macOS
    setup_script_base=$(get_setup_binary_name "$tp2_file" "linux")
    install -m755 "$DIR/scripts/setup-mod.sh" "${setup_script_base}.sh"
    install -m755 "$DIR/scripts/setup-mod.sh" "${setup_script_base}.command"
    if [ $multi_autoupdate -eq 0 ]; then
      sed -i -e 's/autoupdate=1/autoupdate=0/' "${setup_script_base}.sh"
      sed -i -e 's/autoupdate=1/autoupdate=0/' "${setup_script_base}.command"
    fi
    echo "${setup_script_base}.sh" >>"$zip_include"
    echo "${setup_script_base}.command" >>"$zip_include"
    removables+=("${setup_script_base}.sh" "${setup_script_base}.command")
    echo "Setup name: ${setup_script_base}.command"
    echo "Setup name: ${setup_script_base}.sh"

    # Installing Windows setup binary
    weidu_bin="weidu.exe"
    if [ ! -e "$weidu_bin" ]; then
      # Downloading WeiDU binary
      echo "Downloading WeiDU executable: $weidu_bin (windows)"
      download_weidu "windows" "$arch" "$weidu_version" "$weidu_bin"
      if [ $? -ne 0 ]; then
        clean_up "${removables[@]}"
        exit 1
      fi
      if [ ! -e "$weidu_bin" ]; then
        printerr "ERROR: Could not find WeiDU binary on the system."
        clean_up "${removables[@]}"
        exit 1
      fi
      removables+=("$weidu_bin")
    fi
    # Setting up setup binary for Windows
    create_setup_binaries "$weidu_bin" "$tp2_file" "windows"
    if [ $? -ne 0 ]; then
      printerr "ERROR: Could not create setup binaries."
      clean_up "${removables[@]}"
      exit 1
    fi
    setup_file=$(get_setup_binary_name "$tp2_file" "windows")
    echo "${setup_file}" >>"$zip_include"
    removables+=("$setup_file")
    echo "Setup name: $setup_file"
  elif [ "$archive_type" != "iemod" ]; then
    if [ ! -e "$weidu_bin" ]; then
      # Downloading WeiDU binary
      echo "Downloading WeiDU executable: $weidu_bin ($archive_type)"
      download_weidu "$archive_type" "$arch" "$weidu_version"
      if [ $? -ne 0 ]; then
        clean_up "${removables[@]}"
        exit 1
      fi
      if [ ! -e "$weidu_bin" ]; then
        printerr "ERROR: Could not find WeiDU binary on the system."
        clean_up "${removables[@]}"
        exit 1
      fi
      removables+=("$weidu_bin")
      echo "WeiDU binary: $weidu_bin"
    fi

    # Setting up setup binaries
    create_setup_binaries "$weidu_bin" "$tp2_file" "$archive_type"
    if [ $? -ne 0 ]; then
      printerr "ERROR: Could not create setup binaries."
      clean_up "${removables[@]}"
      exit 1
    fi

    setup_file=$(get_setup_binary_name "$tp2_file" "$archive_type")
    echo "${setup_file}" >>"$zip_include"
    removables+=("$setup_file")
    echo "Setup name: $setup_file"

    command_file=$(get_setup_command_name "$tp2_file" "$archive_type")
    if [ -n "$command_file" ]; then
      echo "${command_file}" >>"$zip_include"
      removables+=("$command_file")
      echo "Command script name: $command_file"
    fi
  fi

  # Getting version suffix
  version_suffix="$suffix"
  if [ "$suffix" = "version" ]; then
    version_suffix=$(get_tp2_version "$tp2_file")
  fi
  version_suffix=$(normalize_version "$version_suffix" "_")
  echo "Version suffix: $version_suffix"
  if [ -n "$version_suffix" -a "${version_suffix:0:1}" != "-" ]; then
    version_suffix="-$version_suffix"
  fi

  # getting mod folder and (optional) tp2 file paths
  if [ -z "$tp2_mod_path" ]; then
    tp2_mod_path=$(path_get_parent_path "$tp2_file")
    tp2_file=""
  fi

  # removing duplicate files
  if [ $case_sensitive -eq 0 ]; then
    remove_duplicates "$tp2_mod_path"
    if [ $? -ne 0 ]; then
      clean_up "${removables[@]}"
      exit 1
    fi
  fi

  echo "${tp2_mod_path}/**" >>"$zip_include"
  if [ -n "$tp2_file" ]; then
    echo "${tp2_file}" >>"$zip_include"
  fi

  # PI meta file may exist in the root folder for old-style mods
  ini_file=""
  if [ -n "$tp2_file" ]; then
    file_base=$(path_get_tp2_name "$tp2_file")
    file_root=$(path_get_parent_path "$tp2_file")
    if [ -z "$file_root" ]; then
      file_root="."
    fi
    ini_file=$(find_file "$file_root" "*${file_base}.ini")
  fi

  if [ -n "$ini_file" ]; then
    echo "${ini_file}" >>"$zip_include"
  fi

  # Assembling mod archive filename and path
  if [ -z "$archive_filename" ]; then
    archive_filename=$(create_package_name "$tp2_mod_path" "$version_suffix" "$ini_file")
    archive_file_path="${root}/${archive_filename}"
  fi
done

# Creating mod package
echo "Mod archive: $archive_filename"

# Exclude certain file and folder patterns from the zip archive
cat << "EOF" > "$zip_exclude"
**/.*
**/*.bak
**/*.iemod
**/*.tmp
**/*.temp
**/Thumbs.db
**/ehthumbs.db
**/backup/*
**/__macosx/*
**/$RECYCLE.BIN/*
EOF
removables+=("$zip_include" "$zip_exclude")

# Creating zip archive
zip -r "$archive_file_path" . -i "@$zip_include" -x "@$zip_exclude"

# Cleaning up files
clean_up "${removables[@]}"

# Back to the roots
cd "$root"

# Passing mod package name to the GitHub Action parameter "weidu_mod_package"
echo "Passing mod package name to GitHub Action output..."
echo "weidu_mod_package=$archive_filename" >> $GITHUB_OUTPUT

exit 0
