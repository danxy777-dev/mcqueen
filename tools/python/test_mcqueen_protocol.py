#!/usr/bin/env python3
"""Testes do protocolo McQueen (sem hardware)."""

import unittest

from mcqueen_protocol import (
    calibration_stop_command,
    calibration_vmin_command,
    calibration_vmax_command,
    clamp_percent,
    is_motor_command,
    is_movement_command,
    matches_device,
    movement_command,
    motor_command,
    parse_status,
    speed_command,
    validate_command,
)


class TestMovementCommands(unittest.TestCase):
    def test_default_direction(self):
        self.assertEqual(movement_command("frente"), "FRENTE")

    def test_inline_speed_and_clamp(self):
        self.assertEqual(movement_command("tras", 30), "TRAS:30")
        self.assertEqual(movement_command("ESQUERDA", 150), "ESQUERDA:100")
        self.assertEqual(movement_command("direita", -5), "DIREITA:0")

    def test_invalid_direction(self):
        with self.assertRaises(ValueError):
            movement_command("CIMA")

    def test_speed_command(self):
        self.assertEqual(speed_command(70), "VELOCIDADE:70")
        self.assertEqual(speed_command(150), "VELOCIDADE:100")

    def test_clamp_percent(self):
        self.assertEqual(clamp_percent(-1), 0)
        self.assertEqual(clamp_percent(50), 50)
        self.assertEqual(clamp_percent(101), 100)


class TestMotorAndCalibration(unittest.TestCase):
    def test_motor_command(self):
        self.assertEqual(motor_command("esq", 20), "MOTOR:ESQ:20")
        self.assertEqual(motor_command("DIR", -100), "MOTOR:DIR:-100")

    def test_motor_limits(self):
        with self.assertRaises(ValueError):
            motor_command("ESQ", 101)
        with self.assertRaises(ValueError):
            motor_command("MEIO", 10)

    def test_calibration_stop(self):
        self.assertEqual(calibration_stop_command("ESQ", 1500), "CAL:ESTOPL:1500")
        self.assertEqual(calibration_stop_command("DIR", 1600), "CAL:ESTOPR:1600")

    def test_calibration_range(self):
        with self.assertRaises(ValueError):
            calibration_stop_command("ESQ", 999)
        with self.assertRaises(ValueError):
            calibration_stop_command("DIR", 2001)

    def test_calibration_speed_limits(self):
        self.assertEqual(calibration_vmin_command(15), "CAL:VMIN:15")
        self.assertEqual(calibration_vmax_command(90), "CAL:VMAX:90")
        with self.assertRaises(ValueError):
            calibration_vmin_command(96)
        with self.assertRaises(ValueError):
            calibration_vmax_command(4)


class TestValidation(unittest.TestCase):
    def assertValid(self, cmd):
        ok, reason = validate_command(cmd)
        self.assertTrue(ok, f"{cmd!r} deveria ser válido: {reason}")

    def assertInvalid(self, cmd):
        ok, _ = validate_command(cmd)
        self.assertFalse(ok, f"{cmd!r} deveria ser inválido")

    def test_valid_commands(self):
        for cmd in [
            "FRENTE",
            "FRENTE:0",
            "TRAS:100",
            "ESQUERDA:45",
            "DIREITA",
            "PARAR",
            "PING",
            "STATUS",
            "DIAG",
            "VEL:1",
            "VEL:2",
            "VEL:3",
            "VELOCIDADE:0",
            "VELOCIDADE:100",
            "MOTOR:ESQ:20",
            "MOTOR:DIR:-20",
            "BUZINA",
            "BIPE",
            "ALERTA",
            "CAL:ESTOPL:1500",
            "CAL:ESTOPR:2000",
            "CAL:INVERTEL",
            "CAL:INVERTED",
            "CAL:VMIN:0",
            "CAL:VMIN:25",
            "CAL:VMAX:85",
            "CAL:VMAX:100",
            "CAL:RESET",
            "BUZZER:ATIVO",
            "BUZZER:PASSIVO",
        ]:
            with self.subTest(cmd=cmd):
                self.assertValid(cmd)

    def test_invalid_commands(self):
        for cmd in [
            "",
            " ",
            "FRENTE:",
            "FRENTE:101",
            "FRENTE:-1",
            "VELOCIDADE:101",
            "VELOCIDADE:abc",
            "MOTOR:ESQ:101",
            "MOTOR:MEIO:10",
            "MOTOR:ESQ",
            "CAL:ESTOPL:999",
            "CAL:ESTOPR:2001",
            "DESCONHECIDO",
            "X" * 41,
        ]:
            with self.subTest(cmd=cmd):
                self.assertInvalid(cmd)

    def test_helpers(self):
        self.assertTrue(is_movement_command("FRENTE:30"))
        self.assertTrue(is_movement_command("esq"))
        self.assertFalse(is_movement_command("PARAR"))
        self.assertTrue(is_motor_command("MOTOR:DIR:-10"))
        self.assertFalse(is_motor_command("VEL:3"))


class TestDeviceMatching(unittest.TestCase):
    def test_match_by_device_name(self):
        self.assertTrue(matches_device("McQueen", None, []))
        self.assertTrue(matches_device(" mcqueen ", None, None))

    def test_match_by_advertised_name(self):
        self.assertTrue(matches_device(None, "McQueen", ()))

    def test_match_by_service_uuid(self):
        self.assertTrue(
            matches_device(
                "Outro",
                None,
                ["12345678-1234-5678-1234-56789ABCDEF0"],
            )
        )

    def test_no_match(self):
        self.assertFalse(matches_device("McQueenProbe", "McQueenProbe", []))
        self.assertFalse(matches_device(None, None, ["0000fff0-0000-1000-8000-00805f9b34fb"]))
        self.assertFalse(matches_device(None, None, None))


class TestParseStatus(unittest.TestCase):
    def test_status_parse(self):
        parsed = parse_status("V:70|M:0|L:1500|R:1500|I:01")
        self.assertEqual(
            parsed,
            {"V": 70, "M": 0, "L": 1500, "R": 1500, "I": 1},
        )

    def test_status_ignores_invalid_fields(self):
        self.assertEqual(parse_status("V:70|bad|R:abc"), {"V": 70})

    def test_empty_status(self):
        self.assertEqual(parse_status(""), {})


if __name__ == "__main__":
    unittest.main()
