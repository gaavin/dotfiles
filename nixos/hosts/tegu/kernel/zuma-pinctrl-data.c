/* pin banks of zuma pin-controller (ALIVE) */
static const struct samsung_pin_bank_data zuma_pin_alive[] __initconst = {
	GS101_PIN_BANK_EINTW(4, 0x0, "gpa0", 0x00, 0x00),
	GS101_PIN_BANK_EINTW(6, 0x20, "gpa1", 0x04, 0x04),
	GS101_PIN_BANK_EINTW(4, 0x40, "gpa2", 0x08, 0x0c),
	GS101_PIN_BANK_EINTW(4, 0x60, "gpa3", 0x0c, 0x10),
	GS101_PIN_BANK_EINTW(2, 0x80, "gpa4", 0x10, 0x14),
	GS101_PIN_BANK_EINTW(6, 0xa0, "gpa6", 0x14, 0x18),
	GS101_PIN_BANK_EINTW(8, 0xc0, "gpa7", 0x18, 0x20),
	GS101_PIN_BANK_EINTW(4, 0xe0, "gpa8", 0x1c, 0x28),
	GS101_PIN_BANK_EINTW(7, 0x100, "gpa9", 0x20, 0x2c),
	GS101_PIN_BANK_EINTW(5, 0x120, "gpa10", 0x24, 0x34),
};

/* pin banks of zuma pin-controller (CUSTOM_ALIVE) */
static const struct samsung_pin_bank_data zuma_pin_custom[] __initconst = {
	GS101_PIN_BANK_EINTW(1, 0x0, "gpn0", 0x00, 0x00),
	GS101_PIN_BANK_EINTW(1, 0x20, "gpn1", 0x04, 0x04),
	GS101_PIN_BANK_EINTW(1, 0x40, "gpn2", 0x08, 0x08),
	GS101_PIN_BANK_EINTW(1, 0x60, "gpn3", 0x0c, 0x0c),
	GS101_PIN_BANK_EINTW(1, 0x80, "gpn4", 0x10, 0x10),
	GS101_PIN_BANK_EINTW(1, 0xa0, "gpn5", 0x14, 0x14),
	GS101_PIN_BANK_EINTW(1, 0xc0, "gpn6", 0x18, 0x18),
	GS101_PIN_BANK_EINTW(1, 0xe0, "gpn7", 0x1c, 0x1c),
	GS101_PIN_BANK_EINTW(1, 0x100, "gpn8", 0x20, 0x20),
	GS101_PIN_BANK_EINTW(1, 0x120, "gpn9", 0x24, 0x24),
};

/* pin banks of zuma pin-controller (FAR_ALIVE) */
static const struct samsung_pin_bank_data zuma_pin_far[] __initconst = {
	GS101_PIN_BANK_EINTW(8, 0x0, "gpa5", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (GSACORE0) */
static const struct samsung_pin_bank_data zuma_pin_gsacore0[] __initconst = {
	GS101_PIN_BANK_EINTG(2, 0x0, "gps0", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (GSACORE1) */
static const struct samsung_pin_bank_data zuma_pin_gsacore1[] __initconst = {
	GS101_PIN_BANK_EINTG(4, 0x0, "gps1", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (GSACORE2) */
static const struct samsung_pin_bank_data zuma_pin_gsacore2[] __initconst = {
	GS101_PIN_BANK_EINTG(4, 0x0, "gps2", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (GSACORE3) */
static const struct samsung_pin_bank_data zuma_pin_gsacore3[] __initconst = {
	GS101_PIN_BANK_EINTG(3, 0x0, "gps3", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (GSACTRL) */
static const struct samsung_pin_bank_data zuma_pin_gsactrl[] __initconst = {
	GS101_PIN_BANK_EINTW(4, 0x0, "gps4", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (HSI1) */
static const struct samsung_pin_bank_data zuma_pin_hsi1[] __initconst = {
	GS101_PIN_BANK_EINTG(4, 0x0, "gph0", 0x00, 0x00),
	GS101_PIN_BANK_EINTG(8, 0x20, "gph1", 0x04, 0x04),
	GS101_PIN_BANK_EINTG(4, 0x40, "gph2", 0x08, 0x0c),
};

/* pin banks of zuma pin-controller (HSI2) */
static const struct samsung_pin_bank_data zuma_pin_hsi2[] __initconst = {
	GS101_PIN_BANK_EINTG(6, 0x0, "gph3", 0x00, 0x00),
	GS101_PIN_BANK_EINTG(7, 0x20, "gph4", 0x04, 0x08),
};

/* pin banks of zuma pin-controller (HSI2UFS) */
static const struct samsung_pin_bank_data zuma_pin_hsi2ufs[] __initconst = {
	GS101_PIN_BANK_EINTG(2, 0x0, "gph5", 0x00, 0x00),
};

/* pin banks of zuma pin-controller (PERIC0) */
static const struct samsung_pin_bank_data zuma_pin_peric0[] __initconst = {
	GS101_PIN_BANK_EINTG(5, 0x0, "gpp0", 0x00, 0x00),
	GS101_PIN_BANK_EINTG(4, 0x20, "gpp1", 0x04, 0x08),
	GS101_PIN_BANK_EINTG(4, 0x40, "gpp2", 0x08, 0x0c),
	GS101_PIN_BANK_EINTG(2, 0x60, "gpp3", 0x0c, 0x10),
	GS101_PIN_BANK_EINTG(4, 0x80, "gpp4", 0x10, 0x14),
	GS101_PIN_BANK_EINTG(2, 0xa0, "gpp5", 0x14, 0x18),
	GS101_PIN_BANK_EINTG(4, 0xc0, "gpp6", 0x18, 0x1c),
	GS101_PIN_BANK_EINTG(2, 0xe0, "gpp7", 0x1c, 0x20),
	GS101_PIN_BANK_EINTG(4, 0x100, "gpp8", 0x20, 0x24),
	GS101_PIN_BANK_EINTG(2, 0x120, "gpp9", 0x24, 0x28),
	GS101_PIN_BANK_EINTG(4, 0x140, "gpp10", 0x28, 0x2c),
	GS101_PIN_BANK_EINTG(2, 0x160, "gpp11", 0x2c, 0x30),
	GS101_PIN_BANK_EINTG(4, 0x180, "gpp12", 0x30, 0x34),
	GS101_PIN_BANK_EINTG(2, 0x1a0, "gpp13", 0x34, 0x38),
	GS101_PIN_BANK_EINTG(2, 0x1c0, "gpp14", 0x38, 0x3c),
	GS101_PIN_BANK_EINTG(2, 0x1e0, "gpp15", 0x3c, 0x40),
	GS101_PIN_BANK_EINTG(2, 0x200, "gpp17", 0x40, 0x44),
	GS101_PIN_BANK_EINTG(4, 0x220, "gpp16", 0x44, 0x48),
};

/* pin banks of zuma pin-controller (PERIC1) */
static const struct samsung_pin_bank_data zuma_pin_peric1[] __initconst = {
	GS101_PIN_BANK_EINTG(8, 0x0, "gpp19", 0x00, 0x00),
	GS101_PIN_BANK_EINTG(4, 0x20, "gpp20", 0x04, 0x08),
	GS101_PIN_BANK_EINTG(8, 0x40, "gpp21", 0x08, 0x0c),
	GS101_PIN_BANK_EINTG(4, 0x60, "gpp24", 0x0c, 0x14),
	GS101_PIN_BANK_EINTG(4, 0x80, "gpp22", 0x10, 0x18),
	GS101_PIN_BANK_EINTG(4, 0xa0, "gpp23", 0x14, 0x1c),
};

/*
 * Alive controllers deliberately omit .retention_data. gs101 copies
 * &no_retention_data here, but that is not a no-op: probe calls
 * retention_data->init() (exynos_retention_init), which looks up the
 * Exynos PMU syscon and treats -ENODEV as fatal. Measured on this
 * phone with pinctrl-loud: 15060000.pinctrl reached "soc data ok, 10
 * banks" then "retention -19" and never registered gpn0. PERIC0 has
 * no retention_data and probed. Pad retention is a suspend helper;
 * do not restore until a zumapro PMU driver exists -- gs101's init
 * writes PMU registers at offsets this port has not verified.
 */
static const struct samsung_pin_ctrl zuma_pin_ctrl[] __initconst = {
	{
		/* pin banks of zuma pin-controller (ALIVE) */
		.pin_banks	= zuma_pin_alive,
		.nr_banks	= ARRAY_SIZE(zuma_pin_alive),
		.eint_wkup_init = exynos_eint_wkup_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (CUSTOM_ALIVE) */
		.pin_banks	= zuma_pin_custom,
		.nr_banks	= ARRAY_SIZE(zuma_pin_custom),
		.eint_wkup_init = exynos_eint_wkup_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (FAR_ALIVE) */
		.pin_banks	= zuma_pin_far,
		.nr_banks	= ARRAY_SIZE(zuma_pin_far),
		.eint_wkup_init = exynos_eint_wkup_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (GSACORE0) */
		.pin_banks	= zuma_pin_gsacore0,
		.nr_banks	= ARRAY_SIZE(zuma_pin_gsacore0),
		.eint_gpio_init = exynos_eint_gpio_init,
	}, {
		/* pin banks of zuma pin-controller (GSACORE1) */
		.pin_banks	= zuma_pin_gsacore1,
		.nr_banks	= ARRAY_SIZE(zuma_pin_gsacore1),
		.eint_gpio_init = exynos_eint_gpio_init,
	}, {
		/* pin banks of zuma pin-controller (GSACORE2) */
		.pin_banks	= zuma_pin_gsacore2,
		.nr_banks	= ARRAY_SIZE(zuma_pin_gsacore2),
		.eint_gpio_init = exynos_eint_gpio_init,
	}, {
		/* pin banks of zuma pin-controller (GSACORE3) */
		.pin_banks	= zuma_pin_gsacore3,
		.nr_banks	= ARRAY_SIZE(zuma_pin_gsacore3),
		.eint_gpio_init = exynos_eint_gpio_init,
	}, {
		/* pin banks of zuma pin-controller (GSACTRL) */
		.pin_banks	= zuma_pin_gsactrl,
		.nr_banks	= ARRAY_SIZE(zuma_pin_gsactrl),
		.eint_wkup_init = exynos_eint_wkup_init,
	}, {
		/* pin banks of zuma pin-controller (HSI1) */
		.pin_banks	= zuma_pin_hsi1,
		.nr_banks	= ARRAY_SIZE(zuma_pin_hsi1),
		.eint_gpio_init = exynos_eint_gpio_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (HSI2) */
		.pin_banks	= zuma_pin_hsi2,
		.nr_banks	= ARRAY_SIZE(zuma_pin_hsi2),
		.eint_gpio_init = exynos_eint_gpio_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (HSI2UFS) */
		.pin_banks	= zuma_pin_hsi2ufs,
		.nr_banks	= ARRAY_SIZE(zuma_pin_hsi2ufs),
		.eint_gpio_init = exynos_eint_gpio_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (PERIC0) */
		.pin_banks	= zuma_pin_peric0,
		.nr_banks	= ARRAY_SIZE(zuma_pin_peric0),
		.eint_gpio_init = exynos_eint_gpio_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	}, {
		/* pin banks of zuma pin-controller (PERIC1) */
		.pin_banks	= zuma_pin_peric1,
		.nr_banks	= ARRAY_SIZE(zuma_pin_peric1),
		.eint_gpio_init = exynos_eint_gpio_init,
		.suspend	= gs101_pinctrl_suspend,
		.resume		= gs101_pinctrl_resume,
	},
};

const struct samsung_pinctrl_of_match_data zuma_of_data __initconst = {
	.ctrl		= zuma_pin_ctrl,
	.num_ctrl	= ARRAY_SIZE(zuma_pin_ctrl),
};


