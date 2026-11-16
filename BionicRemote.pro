TARGET = harbour-bionic-remote

CONFIG += sailfishapp

SOURCES += \
    src/client.cpp \
    src/main.cpp

HEADERS += \
    src/client.h

OTHER_FILES += \
    qml/BionicRemote.qml \
    qml/cover/CoverPage.qml \
    qml/pages/ProjectsPage.qml \
    qml/pages/SessionsPage.qml \
    qml/pages/SessionPage.qml \
    qml/pages/SettingsPage.qml \
    harbour-bionic-remote.desktop \
    rpm/harbour-bionic-remote.changes \
    rpm/harbour-bionic-remote.spec
