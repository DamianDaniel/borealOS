#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

int main(int argc, char *argv[])
{
    // WAYLAND: Force Qt to use the Wayland Platform Plugin
    qputenv("QT_QPA_PLATFORM", "WAYLAND");

    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;

    // TODO: Inject logic

    const QUrl url (QStringLiteral("qrc:/qt/qml/qml/main.qml"));

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated, &app, [url] (QObject *obj, const QUrl &objUrl)
    {
       if (!obj && url == objUrl)
           QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);

    engine.load(url);

    return app.exec();
}