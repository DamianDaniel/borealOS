#include <QGuiApplication>
#include <QProcess>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);

    QString qmlPath = QGuiApplication::applicationDirPath() + "/org/borealos/components/qml/main.qml";
    if (!QFile::exists(qmlPath)) {
        qmlPath = QGuiApplication::applicationDirPath() + "/main.qml";
    }
    
    // Absolute path is safer for QProcess
    qmlPath = QDir(qmlPath).absolutePath();

    // The build directory (or where the plugin is)
    // We want the parent of the org/borealos/components directory
    QString importPath = QDir(QGuiApplication::applicationDirPath()).absolutePath();

    QProcess *process = new QProcess(&app);
    QStringList arguments;
    arguments << "-p" << qmlPath;
    
    // Set up environment to ensure wayland is used and our plugin is found
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert("QT_QPA_PLATFORM", "wayland");
    env.insert("QML_IMPORT_PATH", importPath);
    // Also add current dir to library path just in case
    env.insert("LD_LIBRARY_PATH", importPath + ":" + env.value("LD_LIBRARY_PATH"));
    process->setProcessEnvironment(env);

    process->start("quickshell", arguments);
    
    if (!process->waitForStarted()) {
        process->start("qs", arguments);
    }

    return app.exec();
}
