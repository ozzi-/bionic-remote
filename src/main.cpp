#include <QtQuick>

#include <sailfishapp.h>

#include "client.h"

int main(int argc, char *argv[])
{
    QScopedPointer<QGuiApplication> app(SailfishApp::application(argc, argv));
    QScopedPointer<QQuickView> view(SailfishApp::createView());

    QCoreApplication::setApplicationName(QStringLiteral("harbour-bionic-remote"));
    QCoreApplication::setOrganizationName(QStringLiteral("ozzi"));

    Client client;
    view->rootContext()->setContextProperty("client", &client);

    view->setSource(SailfishApp::pathTo("qml/BionicRemote.qml"));
    view->show();

    return app->exec();
}
