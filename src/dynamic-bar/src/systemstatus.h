#pragma once
#include <QObject>
#include <QTimer>
#include <QDateTime>
#include <QFile>
#include <QTextStream>

class SystemStatus : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString currentTime READ currentTime NOTIFY timeChanged)
    Q_PROPERTY(int batteryLevel READ batteryLevel NOTIFY batteryChanged)

public:
    explicit SystemStatus(QObject *parent = nullptr) : QObject(parent) {
        connect(&m_timer, &QTimer::timeout, this, &SystemStatus::updateStatus);
        m_timer.start(5000); // Check every 5 seconds instead of every second to save battery
        updateStatus();
    }

    QString currentTime() const { return m_timeString; }
    int batteryLevel() const { return m_batteryLevel; }

signals:
    void timeChanged();
    void batteryChanged();

private:
    void updateStatus() {
        // 1. Fetch Real Time
        QString newTime = QDateTime::currentDateTime().toString("h:mm AM/PM");
        if (newTime != m_timeString) {
            m_timeString = newTime;
            emit timeChanged();
        }

        // 2. Fetch Real Battery Percentage
        int newBattery = readBatterySysfs();
        if (newBattery != m_batteryLevel) {
            m_batteryLevel = newBattery;
            emit batteryChanged();
        }
    }

    int readBatterySysfs() {
        // Try BAT1 first (common on Steam Deck), fall back to BAT0
        QFile file("/sys/class/power_supply/BAT1/capacity");
        if (!file.exists()) {
            file.setFileName("/sys/class/power_supply/BAT0/capacity");
        }

        if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            QTextStream in(&file);
            QString capacityStr = in.readLine().trimmed();
            file.close();

            bool ok;
            int percentage = capacityStr.toInt(&ok);
            if (ok) {
                return percentage;
            }
        }

        return -1; // Return -1 if reading fails (e.g., if it's a desktop without a battery)
    }

    QTimer m_timer;
    QString m_timeString;
    int m_batteryLevel = 100;
};