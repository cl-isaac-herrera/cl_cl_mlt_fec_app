/**
 * @clavisco/notification-center - Notification center service
 * Migrated from Angular to vanilla JavaScript for Rails/Stimulus
 */

import { clPrint, CL_DISPLAY, Storage } from 'vendor/clavisco/core'
import { publish } from 'vendor/clavisco/linker'
import Swal from 'sweetalert2'

// ============================================================
// NOTIFICATION TYPES
// ============================================================

export const NOTIFICATION_TYPES = {
  INFO: 'info',
  SUCCESS: 'success',
  WARNING: 'warning',
  ERROR: 'error'
}

// ============================================================
// NOTIFICATION SERVICE
// ============================================================

class NotificationCenterService {
  constructor() {
    this.notifications = []
    this.unreadCount = 0
    this.maxNotifications = 100
  }

  /**
   * Load notifications from API
   * @param {string} apiUrl - API base URL
   * @returns {Promise<Array>} Notifications list
   */
  async loadNotifications(apiUrl = '/api') {
    try {
      const response = await fetch(`${apiUrl}/Notifications`, {
        headers: {
          'Authorization': `Bearer ${Storage.getToken()}`,
          'Content-Type': 'application/json',
          'cl-company-id': String(Storage.getCompanyId())
        }
      })

      if (response.ok) {
        const data = await response.json()
        this.notifications = data.Data || data || []
        this.updateUnreadCount()
        return this.notifications
      }

      return []

    } catch (error) {
      clPrint(error, CL_DISPLAY.WARNING)
      return []
    }
  }

  /**
   * Add a notification
   * @param {Object} notification - Notification object
   */
  add(notification) {
    const newNotification = {
      id: Date.now(),
      type: notification.type || NOTIFICATION_TYPES.INFO,
      title: notification.title || '',
      message: notification.message,
      timestamp: new Date(),
      read: false,
      ...notification
    }

    this.notifications.unshift(newNotification)

    // Trim to max
    if (this.notifications.length > this.maxNotifications) {
      this.notifications = this.notifications.slice(0, this.maxNotifications)
    }

    this.updateUnreadCount()
    this.notifyChange()

    // Also show toast
    this.showToast(newNotification)

    return newNotification
  }

  /**
   * Show toast notification
   * @param {Object} notification - Notification object
   */
  showToast(notification) {
    Swal.fire({
      toast: true,
      position: 'top-end',
      icon: notification.type,
      title: notification.message,
      showConfirmButton: false,
      timer: 3000,
      timerProgressBar: true
    })
  }

  /**
   * Mark notification as read
   * @param {number} notificationId - Notification ID
   */
  markAsRead(notificationId) {
    const notification = this.notifications.find(n => n.id === notificationId)
    if (notification) {
      notification.read = true
      this.updateUnreadCount()
      this.notifyChange()
    }
  }

  /**
   * Mark all notifications as read
   */
  markAllAsRead() {
    this.notifications.forEach(n => n.read = true)
    this.updateUnreadCount()
    this.notifyChange()
  }

  /**
   * Remove a notification
   * @param {number} notificationId - Notification ID
   */
  remove(notificationId) {
    this.notifications = this.notifications.filter(n => n.id !== notificationId)
    this.updateUnreadCount()
    this.notifyChange()
  }

  /**
   * Clear all notifications
   */
  clearAll() {
    this.notifications = []
    this.unreadCount = 0
    this.notifyChange()
  }

  /**
   * Get all notifications
   * @returns {Array} Notifications list
   */
  getNotifications() {
    return this.notifications
  }

  /**
   * Get unread count
   * @returns {number} Unread count
   */
  getUnreadCount() {
    return this.unreadCount
  }

  /**
   * Update unread count
   */
  updateUnreadCount() {
    this.unreadCount = this.notifications.filter(n => !n.read).length
  }

  /**
   * Notify subscribers of changes
   */
  notifyChange() {
    publish({
      View: 'notification-center',
      Target: 'update',
      Data: {
        notifications: this.notifications,
        unreadCount: this.unreadCount
      }
    })

    document.dispatchEvent(new CustomEvent('cl-notifications-change', {
      detail: {
        notifications: this.notifications,
        unreadCount: this.unreadCount
      }
    }))
  }

  /**
   * Convenience methods for different notification types
   */
  info(message, title = '') {
    return this.add({ type: NOTIFICATION_TYPES.INFO, message, title })
  }

  success(message, title = '') {
    return this.add({ type: NOTIFICATION_TYPES.SUCCESS, message, title })
  }

  warning(message, title = '') {
    return this.add({ type: NOTIFICATION_TYPES.WARNING, message, title })
  }

  error(message, title = '') {
    return this.add({ type: NOTIFICATION_TYPES.ERROR, message, title })
  }
}

// Singleton instance
const notificationCenter = new NotificationCenterService()

// ============================================================
// EXPORTS
// ============================================================

export const NotificationCenter = notificationCenter

export function loadNotifications(apiUrl) {
  return notificationCenter.loadNotifications(apiUrl)
}

export function add(notification) {
  return notificationCenter.add(notification)
}

export function markAsRead(id) {
  notificationCenter.markAsRead(id)
}

export function markAllAsRead() {
  notificationCenter.markAllAsRead()
}

export function remove(id) {
  notificationCenter.remove(id)
}

export function clearAll() {
  notificationCenter.clearAll()
}

export function getNotifications() {
  return notificationCenter.getNotifications()
}

export function getUnreadCount() {
  return notificationCenter.getUnreadCount()
}

export function info(message, title) {
  return notificationCenter.info(message, title)
}

export function success(message, title) {
  return notificationCenter.success(message, title)
}

export function warning(message, title) {
  return notificationCenter.warning(message, title)
}

export function error(message, title) {
  return notificationCenter.error(message, title)
}

export default {
  NotificationCenter,
  NOTIFICATION_TYPES,
  loadNotifications,
  add,
  markAsRead,
  markAllAsRead,
  remove,
  clearAll,
  getNotifications,
  getUnreadCount,
  info,
  success,
  warning,
  error
}
