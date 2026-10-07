# Loaded by every python in the image. MLflow (3.x) saves torch models as pt2 (torch.export) by default, and MLflow
# refuses to load a pt2 model on another device than the one it was exported on: trained on CPU -> fails on a GPU
# endpoint ("contains weights / buffers on 'cpu' device, it can't be loaded on 'cuda'"), and the other way round.
# So move the exported program to the device MLflow serves on (same choice as mlflow.pytorch._load_pyfunc).
import os

import torch
import torch.export
from torch.export.passes import move_to_device_pass

_load = torch.export.load


def _load_on_serving_device(*args, **kwargs):
    dev = os.environ.get("MLFLOW_DEFAULT_PREDICTION_DEVICE") or ("cuda" if torch.cuda.is_available() else "cpu")
    return move_to_device_pass(_load(*args, **kwargs), dev)


torch.export.load = _load_on_serving_device
