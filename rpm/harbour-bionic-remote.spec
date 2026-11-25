Name:       harbour-bionic-remote
%global _missing_build_ids_terminate_build 0
%{!?qtc_qmake:%define qtc_qmake %qmake}
%{!?qtc_qmake5:%define qtc_qmake5 %qmake5}
%{!?qtc_make:%define qtc_make make}
%{?qtc_builddir:%define _builddir %qtc_builddir}
Summary:    Bionic Remote
Version:    0.1.0
Release:    11
Group:      Qt/Qt
License:    MIT
URL:        https://github.com/ozzi-
Source0:    %{name}-%{version}.tar.bz2
Requires:   sailfishsilica-qt5 >= 0.10.9
BuildRequires:  pkgconfig(sailfishapp) >= 1.0.2
BuildRequires:  pkgconfig(Qt5Core)
BuildRequires:  pkgconfig(Qt5Network)
BuildRequires:  pkgconfig(Qt5Qml)
BuildRequires:  pkgconfig(Qt5Quick)
BuildRequires:  desktop-file-utils

%description

Bionic Remote watches LM Studio Bionic agent sessions on your LAN:
browse projects, follow live agent progress, and read transcripts.
It talks to a small bridge daemon that exposes Bionic's on-disk
session stores over a token-authenticated HTTP API.

%prep
%setup -q -n %{name}-%{version}

# NOTE: mb2/sfdk does not run the prep section, so the source tree is NOT
# unpacked into a name-version directory the way a stock rpmbuild %setup would
# do it. The tree lives either at %{_builddir}/%{name}-%{version} (when a stock
# %setup ran, e.g. some aarch64 flows) or directly at %{_builddir} (sfdk
# in-place / mb2). Resolve the real source root robustly for both cases.
%build
if [ -d %{_builddir}/%{name}-%{version} ]; then
  cd %{_builddir}/%{name}-%{version}
else
  cd %{_builddir}
fi
qmake BionicRemote.pro
make

%install
rm -rf %{buildroot}
if [ -d %{_builddir}/%{name}-%{version} ]; then
  cd %{_builddir}/%{name}-%{version}
else
  cd %{_builddir}
fi
make INSTALL_ROOT=%{buildroot} install

desktop-file-install --delete-original       \
  --dir %{buildroot}%{_datadir}/applications             \
   %{buildroot}%{_datadir}/applications/*.desktop

%files
%defattr(-,root,root,-)
%{_bindir}/%{name}
%{_datadir}/%{name}
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/*/apps/%{name}.png
