Name:           puppet-format
Version:        1.0.0
Release:        1%{?dist}
Summary:        Puppet source code formatter

License:        BSD-2-Clause

Source0:        puppet-format
Source1:        README.md

BuildArch:      noarch

Requires:       ruby >= 3.0

%description
puppet-format is a Puppet source code formatter with configurable
indentation, resource layout, relationship normalization, assignment
alignment, and hash rocket alignment.

%prep
mkdir -p %{name}-%{version}
cp -p %{SOURCE0} %{name}-%{version}/puppet-format
cp -p %{SOURCE1} %{name}-%{version}/README.md

%build
# Nothing to build.

%install
rm -rf %{buildroot}

install -Dpm 0755 \
    %{name}-%{version}/puppet-format \
    %{buildroot}%{_bindir}/puppet-format

install -Dpm 0644 \
    %{name}-%{version}/README.md \
    %{buildroot}%{_docdir}/%{name}/README.md

%files
%{_bindir}/puppet-format
%doc %{_docdir}/%{name}/README.md

%changelog
* Mon Aug 24 2026 Nopius <nopius@nopius.com> - 1.0.0-1
- Initial package
