#ifndef CLIENT_H
#define CLIENT_H

#include <QObject>

class QNetworkAccessManager;

class Client : public QObject
{
    Q_OBJECT
public:
    explicit Client(QObject *parent = nullptr);

    Q_INVOKABLE QString serverUrl() const;
    Q_INVOKABLE void setServerUrl(const QString &url);
    Q_INVOKABLE QString token() const;
    Q_INVOKABLE void setToken(const QString &token);

    Q_INVOKABLE void fetchProjects();
    Q_INVOKABLE void fetchSessions(const QString &projectId);
    Q_INVOKABLE void fetchTranscript(const QString &projectId, const QString &sessionId, int limit);
    Q_INVOKABLE void testConnection();

Q_SIGNALS:
    void projectsResult(bool ok, const QString &json, const QString &error);
    void sessionsResult(bool ok, const QString &json, const QString &error);
    void transcriptResult(bool ok, const QString &json, const QString &error);
    void healthResult(bool ok, const QString &json, const QString &error);

private:
    enum Endpoint { Projects, Sessions, Transcript, Health };

    QNetworkAccessManager *m_manager;
    QString m_serverUrl;
    QString m_token;

    void doFetch(Endpoint endpoint, const QString &path);
    void emitResult(Endpoint endpoint, bool ok, const QString &json, const QString &error);
    static QString extractError(const QByteArray &body);
};

#endif // CLIENT_H
