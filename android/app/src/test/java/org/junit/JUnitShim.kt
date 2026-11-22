package org.junit

@Target(AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.RUNTIME)
annotation class Test

object Assert {
    fun assertTrue(condition: Boolean) {
        if (!condition) throw AssertionError("Expected true, but was false")
    }

    fun assertFalse(condition: Boolean) {
        if (condition) throw AssertionError("Expected false, but was true")
    }

    fun assertNotNull(value: Any?) {
        if (value == null) throw AssertionError("Expected non-null value")
    }

    fun assertNull(value: Any?) {
        if (value != null) throw AssertionError("Expected null, but was $value")
    }

    fun assertEquals(expected: Any?, actual: Any?) {
        if (expected != actual) {
            throw AssertionError("Expected <$expected> but was <$actual>")
        }
    }

    fun assertEquals(expected: Double, actual: Double, delta: Double) {
        if (kotlin.math.abs(expected - actual) > delta) {
            throw AssertionError("Expected <$expected> ±$delta but was <$actual>")
        }
    }
}
