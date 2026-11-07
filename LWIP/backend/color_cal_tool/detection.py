"""Local chart detector; no dependency on the LWIP service."""
import cv2
import numpy as np

DETECTION_MAX_DIMENSION = 1600

def _detection_frame(image: np.ndarray) -> tuple[np.ndarray, float]:
    """Downscaled greyscale used by both detectors, plus the scale applied."""
    height, width = image.shape[:2]
    scale = min(1.0, DETECTION_MAX_DIMENSION / max(height, width))
    if scale < 1.0:
        image = cv2.resize(
            image,
            (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    if image.ndim == 2:
        return image, scale
    if image.shape[2] == 4:
        return cv2.cvtColor(image, cv2.COLOR_BGRA2GRAY), scale
    return cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), scale

def _largest_contour_in_frame(gray: np.ndarray):
    """The threshold/contour pipeline `_largest_content_contour` runs, minus
    the scale bookkeeping — factored out so `_estimate_skew` can re-run it on
    a small, already-detection-sized frame it has itself rotated, without
    paying for another downscale each time."""
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    _value, threshold = cv2.threshold(
        blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    closed = cv2.morphologyEx(threshold, cv2.MORPH_CLOSE, kernel)
    contours, _hierarchy = cv2.findContours(
        closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return None
    return max(contours, key=cv2.contourArea)

def _largest_content_contour(image: np.ndarray, prepared=None):
    gray, scale = _detection_frame(image) if prepared is None else prepared
    contour = _largest_contour_in_frame(gray)
    if contour is None:
        return None
    return contour if scale == 1.0 else contour.astype(np.float32) / scale
