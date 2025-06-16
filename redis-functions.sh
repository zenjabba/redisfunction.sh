#!/bin/bash

# Redis Functions Library
# Common functions for Redis-based notification state management
# Source this file to use Redis for tracking notification states
#
# Features:
# - Centralized state management across multiple servers
# - Automatic expiration of old states with TTL
# - Atomic operations to prevent race conditions
# - Graceful fallback to flag files if Redis is unavailable
# - Proper error handling and logging

# Redis Configuration
REDIS_HOST="${REDIS_HOST:-192.168.0.175}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_TIMEOUT="${REDIS_TIMEOUT:-5}"
REDIS_KEY_PREFIX="ceph:notifications"
REDIS_DEFAULT_TTL=3600  # 1 hour default TTL for notification states

# Function to test Redis connectivity
test_redis_connection() {
    if command -v redis-cli >/dev/null 2>&1; then
        if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Function to set a notification state in Redis
# Usage: set_redis_notification_state "script_name" "device_class" "state" [ttl_seconds]
set_redis_notification_state() {
    local script_name="$1"
    local device_class="$2" 
    local state="$3"
    local ttl="${4:-$REDIS_DEFAULT_TTL}"
    local timestamp
    timestamp=$(date +%s)
    
    local redis_key="${REDIS_KEY_PREFIX}:${script_name}:${device_class}:${state}"
    
    if test_redis_connection; then
        if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
           SETEX "$redis_key" "$ttl" "$timestamp" >/dev/null 2>&1; then
            return 0
        else
            echo "Warning: Failed to set Redis notification state: $redis_key" >&2
            return 1
        fi
    else
        echo "Warning: Redis connection failed, falling back to flag files" >&2
        return 1
    fi
}

# Function to check if a notification state exists in Redis
# Usage: check_redis_notification_state "script_name" "device_class" "state"
check_redis_notification_state() {
    local script_name="$1"
    local device_class="$2"
    local state="$3"
    
    local redis_key="${REDIS_KEY_PREFIX}:${script_name}:${device_class}:${state}"
    
    if test_redis_connection; then
        if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
           EXISTS "$redis_key" 2>/dev/null | grep -q "1"; then
            return 0  # Key exists
        else
            return 1  # Key doesn't exist
        fi
    else
        echo "Warning: Redis connection failed, falling back to flag files" >&2
        return 1
    fi
}

# Function to delete a notification state from Redis
# Usage: delete_redis_notification_state "script_name" "device_class" "state"
delete_redis_notification_state() {
    local script_name="$1"
    local device_class="$2"
    local state="$3"
    
    local redis_key="${REDIS_KEY_PREFIX}:${script_name}:${device_class}:${state}"
    
    if test_redis_connection; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
                  DEL "$redis_key" >/dev/null 2>&1
        return $?
    else
        echo "Warning: Redis connection failed, falling back to flag files" >&2
        return 1
    fi
}

# Function to get all notification states for debugging
# Usage: list_redis_notification_states [script_name]
list_redis_notification_states() {
    local script_name="${1:-*}"
    local pattern="${REDIS_KEY_PREFIX}:${script_name}:*"
    
    if test_redis_connection; then
        echo "Current notification states in Redis:"
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
                  KEYS "$pattern" 2>/dev/null | while read -r key; do
            if [ -n "$key" ]; then
                local value
                local ttl
                value=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$key" 2>/dev/null)
                ttl=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" TTL "$key" 2>/dev/null)
                echo "  $key = $value (TTL: ${ttl}s)"
            fi
        done
    else
        echo "Warning: Redis connection failed" >&2
        return 1
    fi
}

# Function to clean up expired notification states (manual cleanup if needed)
cleanup_redis_notification_states() {
    local script_name="${1:-*}"
    local pattern="${REDIS_KEY_PREFIX}:${script_name}:*"
    
    if test_redis_connection; then
        local count=0
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
                  KEYS "$pattern" 2>/dev/null | while read -r key; do
            if [ -n "$key" ]; then
                local ttl
                ttl=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" TTL "$key" 2>/dev/null)
                if [ "$ttl" = "-1" ]; then
                    # Key exists but has no TTL, set one
                    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
                              EXPIRE "$key" "$REDIS_DEFAULT_TTL" >/dev/null 2>&1
                    count=$((count + 1))
                fi
            fi
        done
        if [ "$count" -gt 0 ]; then
            echo "Added TTL to $count Redis keys that were missing expiration"
        fi
    else
        echo "Warning: Redis connection failed" >&2
        return 1
    fi
}

# Enhanced notification state functions that combine Redis with flag file fallback
# These functions will try Redis first, then fall back to flag files if Redis is unavailable

# Function to set notification state (Redis with flag file fallback)
set_notification_state() {
    local script_name="$1"
    local device_class="$2"
    local state="$3"
    local ttl="${4:-$REDIS_DEFAULT_TTL}"
    
    # Try Redis first
    if set_redis_notification_state "$script_name" "$device_class" "$state" "$ttl"; then
        return 0
    else
        # Fallback to flag file
        local flag_file="/tmp/ceph-${script_name}-${device_class}-${state}-notified"
        touch "$flag_file"
        return $?
    fi
}

# Function to check notification state (Redis with flag file fallback)
check_notification_state() {
    local script_name="$1"
    local device_class="$2"
    local state="$3"
    
    # Try Redis first
    if test_redis_connection; then
        check_redis_notification_state "$script_name" "$device_class" "$state"
        return $?
    else
        # Fallback to flag file
        local flag_file="/tmp/ceph-${script_name}-${device_class}-${state}-notified"
        [ -f "$flag_file" ]
        return $?
    fi
}

# Function to delete notification state (Redis with flag file fallback)
delete_notification_state() {
    local script_name="$1"
    local device_class="$2"
    local state="$3"
    
    # Try Redis first
    if test_redis_connection; then
        delete_redis_notification_state "$script_name" "$device_class" "$state"
    else
        # Fallback to flag file
        local flag_file="/tmp/ceph-${script_name}-${device_class}-${state}-notified"
        rm -f "$flag_file"
    fi
}

# Function to test the Redis notification system
test_redis_notifications() {
    echo "Testing Redis notification system..."
    echo "Redis server: $REDIS_HOST:$REDIS_PORT"
    
    if test_redis_connection; then
        echo "✅ Redis connection successful"
        
        # Test setting and checking a state
        echo "Testing notification state operations..."
        if set_notification_state "test" "hdd" "paused" 60; then
            echo "✅ Successfully set test notification state"
            
            if check_notification_state "test" "hdd" "paused"; then
                echo "✅ Successfully checked test notification state"
            else
                echo "❌ Failed to check test notification state"
            fi
            
            # Clean up test state
            delete_notification_state "test" "hdd" "paused"
            echo "✅ Cleaned up test notification state"
        else
            echo "❌ Failed to set test notification state"
        fi
    else
        echo "❌ Redis connection failed - will use flag file fallback"
        
        # Test flag file fallback
        echo "Testing flag file fallback..."
        if set_notification_state "test" "hdd" "paused"; then
            echo "✅ Successfully set test notification state (flag file)"
            if check_notification_state "test" "hdd" "paused"; then
                echo "✅ Successfully checked test notification state (flag file)"
            else
                echo "❌ Failed to check test notification state (flag file)"
            fi
            delete_notification_state "test" "hdd" "paused"
            echo "✅ Cleaned up test notification state (flag file)"
        else
            echo "❌ Failed to set test notification state (flag file)"
        fi
    fi
} 