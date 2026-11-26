#include "client.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSettings>
#include <QDebug>
#include <QCoreApplication>

Client::Client(QObject *parent)
    : QObject(parent)
    , m_manager(new QNetworkAccessManager(this))
{
    QSettings settings;
    // No default URL: the bridge host differs per user (LAN IP or Tailscale
    // IP). An empty URL makes the app report "No server configured" until the
    // user enters one in Settings — and keeps no personal IP in the binary.
    m_serverUrl = settings.value(QStringLiteral("serverUrl")).toString();
    m_token = settings.value(QStringLiteral("token")).toString();
    qInfo().noquote() << QStringLiteral("[BRC] settings file: %1")
                       .arg(settings.fileName().toLocal8Bit().constData());
    qInfo().noquote() << QStringLiteral("[BRC] org=%1 app=%2 serverUrl=%3 tokenLen=%4 allKeys=%5")
                       .arg(QCoreApplication::organizationName())
                       .arg(QCoreApplication::applicationName())
                       .arg(m_serverUrl)
                       .arg(m_token.length())
                       .arg(settings.allKeys().join(","));
}

QString Client::serverUrl() const
{
    return m_serverUrl;
}

void Client::setServerUrl(const QString &url)
{
    QString normalized = url.trimmed();
    while (normalized.endsWith(QLatin1Char('/')))
        normalized.chop(1);
    if (normalized.isEmpty() || normalized == m_serverUrl)
        return;
    m_serverUrl = normalized;
    QSettings().setValue(QStringLiteral("serverUrl"), m_serverUrl);
}

QString Client::token() const
{
    return m_token;
}

void Client::setToken(const QString &token)
{
    const QString normalized = token.trimmed();
    if (normalized == m_token)
        return;
    m_token = normalized;
    QSettings().setValue(QStringLiteral("token"), m_token);
}

void Client::fetchProjects()
{
    doFetch(Projects, QStringLiteral("/v1/projects"));
}

void Client::fetchSessions(const QString &projectId)
{
    doFetch(Sessions, QStringLiteral("/v1/projects/") + projectId + QStringLiteral("/sessions"));
}

void Client::fetchTranscript(const QString &projectId, const QString &sessionId, int limit)
{
    doFetch(Transcript, QStringLiteral("/v1/projects/") + projectId
            + QStringLiteral("/sessions/") + sessionId
            + QStringLiteral("/transcript?limit=") + QString::number(limit));
}

void Client::testConnection()
{
    doFetch(Health, QStringLiteral("/v1/health"));
}

void Client::approveChoice(const QString &projectId, const QString &sessionId, const QString &choice)
{
    const QJsonObject payload{{ QStringLiteral("choice"), choice }};
    const QByteArray body = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    doPost(Approve, QStringLiteral("/v1/projects/") + projectId
             + QStringLiteral("/sessions/") + sessionId
             + QStringLiteral("/approve"), body);
}

void Client::doFetch(Endpoint endpoint, const QString &path)
{
    qInfo().noquote() << QStringLiteral("[BRC] fetch %1 -> %2 (tokenLen=%3)")
                      .arg(endpoint).arg(m_serverUrl + path).arg(m_token.length());
    if (m_serverUrl.isEmpty()) {
        emitResult(endpoint, false, QString(), tr("No server configured"));
        return;
    }

    QNetworkRequest request(QUrl::fromUserInput(m_serverUrl + path));
    request.setRawHeader("Authorization", ("Bearer " + m_token).toUtf8());

    QNetworkReply *reply = m_manager->get(request);
    QObject::connect(reply, &QNetworkReply::finished, this, [this, endpoint, reply]() {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool ok = reply->error() == QNetworkReply::NoError
                        && status >= 200 && status < 300;
        const QByteArray body = reply->readAll();

        QString error;
        if (!ok) {
            error = extractError(body);
            if (error.isEmpty())
                error = reply->errorString();
            if (error.isEmpty())
                error = tr("HTTP %1").arg(status);
        }

        // NOTE: deliberately do NOT log the response body — it contains
        // session names / transcript content. (Error text is extracted and
        // shown to the UI separately.)
        qInfo().noquote() << QStringLiteral("[BRC] done %1 status=%2 err=%3")
                          .arg(endpoint).arg(status)
                          .arg(reply->errorString());
        reply->deleteLater();
        emitResult(endpoint, ok, QString::fromUtf8(body), error);
    });
}

void Client::doPost(Endpoint endpoint, const QString &path, const QByteArray &body)
{
    qInfo().noquote() << QStringLiteral("[BRC] post %1 -> %2 (tokenLen=%3)")
                      .arg(endpoint).arg(m_serverUrl + path).arg(m_token.length());
    if (m_serverUrl.isEmpty()) {
        emitResult(endpoint, false, QString(), tr("No server configured"));
        return;
    }

    QNetworkRequest request(QUrl::fromUserInput(m_serverUrl + path));
    request.setRawHeader("Authorization", ("Bearer " + m_token).toUtf8());
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");

    QNetworkReply *reply = m_manager->post(request, body);
    QObject::connect(reply, &QNetworkReply::finished, this, [this, endpoint, reply]() {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool ok = reply->error() == QNetworkReply::NoError
                        && status >= 200 && status < 300;
        const QByteArray respBody = reply->readAll();
        QString error;
        if (!ok) {
            error = extractError(respBody);
            if (error.isEmpty())
                error = reply->errorString();
            if (error.isEmpty())
                error = tr("HTTP %1").arg(status);
        }
        qInfo().noquote() << QStringLiteral("[BRC] done %1 status=%2 err=%3")
                          .arg(endpoint).arg(status).arg(reply->errorString());
        reply->deleteLater();
        emitResult(endpoint, ok, QString::fromUtf8(respBody), error);
    });
}

QString Client::extractError(const QByteArray &body)
{
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(body, &parseError);
    if (doc.isNull() || !doc.isObject())
        return QString();
    return doc.object().value(QStringLiteral("error")).toString().trimmed();
}

void Client::emitResult(Endpoint endpoint, bool ok, const QString &json, const QString &error)
{
    switch (endpoint) {
    case Projects:
        emit projectsResult(ok, json, error);
        break;
    case Sessions:
        emit sessionsResult(ok, json, error);
        break;
    case Transcript:
        emit transcriptResult(ok, json, error);
        break;
    case Health:
        emit healthResult(ok, json, error);
        break;
    case Approve:
        emit approveResult(ok, json, error);
        break;
    }
}
