Name:           puppet-format
Version:        1.1.0
Release:        1%{?dist}
Summary:        Puppet source code formatter

License:        BSD-2-Clause

Source0:         %{name}-%{version}.tar.gz
BuildArch:      noarch
BuildRequires:  pandoc
Requires:       ruby >= 3.0

%description
puppet-format is a Puppet manifest formatter with configurable
indentation and lexer-aware source transformations

%prep
%autosetup


%build
pandoc \
    --standalone \
    --to man \
    %{name}.1.md \
    -o %{name}.1

%install
rm -rf %{buildroot}

install -Dpm 0755 \
    %{name} \
    %{buildroot}%{_bindir}/%{name}

install -Dpm 0644 \
    %{name}.1 \
    %{buildroot}%{_mandir}/man1/%{name}.1

install -Dpm 0644 \
    README.md \
    %{buildroot}%{_docdir}/%{name}/README.md

%files
%{_bindir}/%{name}
%{_mandir}/man1/%{name}.1*
%doc %{_docdir}/%{name}/README.md

%changelog
* Mon Aug 31 2026 Nopius <nopius@nopius.com> - 1.1.0-1
- added option --split-one-line-collections (split one-line array/hash into many lines)
- updated manuals for the new option

* Mon Aug 24 2026 Nopius <nopius@nopius.com> - 1.0.0-4
- added option --[no-]align-array-elements for multiline arrays
- added man page puppet-format.1
- changed SOURCE to .tar.gz

* Mon Aug 24 2026 Nopius <nopius@nopius.com> - 1.0.0-3
- .spec file fixed: changelog added

* Mon Aug 24 2026 Nopius <nopius@nopius.com> - 1.0.0-2
- script name fixed in --help: puppet-format-4sp -> puppet-format
- removed extra # with duplicated ruby options

* Mon Aug 24 2026 Nopius <nopius@nopius.com> - 1.0.0-1
- Initial package
