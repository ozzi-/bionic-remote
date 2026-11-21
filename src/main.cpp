#include <QtQuick>

#include <sailfishapp.h>

#include "client.h"

int main(int argc, char *argv[])
{
    QScopedPointer<QGuiApplication> app(SailfishApp::application(argc, argv));
    QScopedPointer<QQuickView> view(SailfishApp::createView());

    // IMPORTANT: set the application/organization identity BEFORE constructing
    // anything that reads QSettings. Client reads its config (serverUrl/token)
    // from QSettings in its constructor; if the identity is not set yet, QSettings
    // resolves to the wrong file and the app silently falls back to defaults.
    QCoreApplication::setApplicationName(QStringLiteral("harbour-bionic-remote"));
    QCoreApplication::setOrganizationName(QStringLiteral("ozzi"));

    Client client;
    view->rootContext()->setContextProperty("client", &client);

    view->setSource(SailfishApp::pathTo("qml/BionicRemote.qml"));
    view->show();

    return app->exec();
}
